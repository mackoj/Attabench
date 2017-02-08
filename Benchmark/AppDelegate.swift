//
//  AppDelegate.swift
//  Benchmark
//
//  Created by Károly Lőrentey on 2017-01-19.
//  Copyright © 2017. Károly Lőrentey. All rights reserved.
//

import Cocoa
import GlueKit
import BenchmarkingTools
import CollectionBenchmarks

let minimumScale = 4
let maximumScale = 28

@NSApplicationMain
class AppDelegate: NSObject {

    @IBOutlet weak var window: NSWindow!
    @IBOutlet weak var runButton: NSButton!
    @IBOutlet weak var suitePopUpButton: NSPopUpButton!
    @IBOutlet weak var maxSizePopUpButton: NSPopUpButton!
    @IBOutlet weak var benchmarksPopUpButton: NSPopUpButton!
    @IBOutlet weak var startMenuItem: NSMenuItem!
    @IBOutlet weak var progressButton: NSButton!
    @IBOutlet weak var chartImageView: DraggableImageView!

    let runner = Runner()

    let progressRefreshDelay = 0.1
    var progressRefreshScheduled = false
    var nextProgressUpdate = Date.distantPast

    let chartRefreshDelay = 0.25
    var chartRefreshScheduled = false
    var saveScheduled = false
    var terminating = false
    var waitingForParamsChange = false

    let amortized: AnyUpdatableValue<Bool> = UserDefaults.standard.glue.updatable(forKey: "Amortized", defaultValue: false)

    let randomizeInputs: AnyUpdatableValue<Bool> = UserDefaults.standard.glue.updatable(forKey: "RandomizeInputs", defaultValue: false)

    var status: String = "" {
        didSet {
            guard !progressRefreshScheduled else { return }
            let now = Date()
            if nextProgressUpdate < now {
                self.progressButton.title = status
                nextProgressUpdate = now.addingTimeInterval(progressRefreshDelay)
            }
            else {
                scheduleProgressRefresh()
            }
        }
    }

    var selectedSuite: BenchmarkSuiteProtocol? {
        didSet {
            guard let suite = selectedSuite else { return }
            let defaults = UserDefaults.standard
            defaults.set(suite.title, forKey: "SelectedSuite")

            if let menu = self.suitePopUpButton.menu {
                let item = menu.items.first(where: { $0.title == suite.title })
                if self.suitePopUpButton.selectedItem !== item {
                    self.suitePopUpButton.select(item)
                }
            }
            refreshChart()
            refreshMaxScale()
            refreshBenchmarks()
            refreshRunnerParams()
        }
    }
}

extension AppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        window.titleVisibility = .hidden

        self.status = "Loading benchmarks"
        self.runButton.isEnabled = false
        self.startMenuItem.isEnabled = false

        runner.delegate = self
        for suite in CollectionBenchmarks.generateBenchmarks() {
            runner.load(suite)
        }

        if runner.suites.isEmpty {
            self.status = "No benchmarks available"
            return
        }
        self.status = "Ready"
        self.runButton.isEnabled = true
        self.startMenuItem.isEnabled = true

        let defaults = UserDefaults.standard
        let selectedTitle = defaults.string(forKey: "SelectedSuite")
        let suite = runner.suites.first(where: { $0.title == selectedTitle }) ?? runner.suites.first!

        let suiteMenu = NSMenu()
        suiteMenu.removeAllItems()
        var i = 1
        for suite in runner.suites {
            let item = NSMenuItem(title: suite.title,
                                  action: #selector(AppDelegate.didSelectSuite(_:)),
                                  keyEquivalent: i <= 9 ? "\(i)" : "")
            suiteMenu.addItem(item)
            i += 1
        }
        self.suitePopUpButton.menu = suiteMenu

        let sizeMenu = NSMenu()
        for i in minimumScale ... maximumScale {
            let item = NSMenuItem(title: "≤\((1 << i).label)",
                action: #selector(AppDelegate.didSelectMaxSize(_:)),
                keyEquivalent: "")
            item.tag = i
            sizeMenu.addItem(item)
        }
        self.maxSizePopUpButton.menu = sizeMenu

        self.selectedSuite = suite

        self.glue.connector.connect(self.amortized.futureValues) { value in
            self.refreshChart()
        }
        self.glue.connector.connect(self.randomizeInputs.futureValues) { value in
            self.refreshRunnerParams()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplicationTerminateReply {
        if runner.state == .idle {
            return .terminateNow
        }
        terminating = true
        self.stop()
        return .terminateLater
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        self.save()
    }
}

extension AppDelegate: RunnerDelegate {
    //MARK: RunnerDelegate
    func runner(_ runner: Runner, didStartMeasuringSuite suite: String, benchmark: String, size: Int) {
        self.status = "Measuring \(suite) : \(size.label) : \(benchmark)"
    }

    func runner(_ runner: Runner, didMeasureInstanceInSuite suite: String, benchmark: String, size: Int, withResult time: TimeInterval) {
        //print(benchmark, size, time)
        scheduleChartRefresh()
        window.isDocumentEdited = true
        scheduleSave()
    }

    func runner(_ runner: Runner, didStopMeasuringSuite suite: String) {
        self.save()
        if terminating {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        if !terminating && waitingForParamsChange {
            waitingForParamsChange = false
            self.start()
        }
        else {
            self.runButton.image = #imageLiteral(resourceName: "RunTemplate")
            self.runButton.isEnabled = true
            self.startMenuItem.title = "Start Running"
            self.startMenuItem.isEnabled = true
            self.status = "Idle"
        }
    }
}

extension AppDelegate {
    //MARK: Actions

    static let imageSize = CGSize(width: 1280, height: 720)

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(AppDelegate.run(_:)) {
            return runner.state != .stopping
        }
        return true
    }

    func scheduleProgressRefresh() {
        if !progressRefreshScheduled {
            self.perform(#selector(AppDelegate.refreshProgress), with: nil, afterDelay: progressRefreshDelay)
            progressRefreshScheduled = true
        }
    }

    func refreshProgress() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(AppDelegate.refreshProgress), object: nil)
        progressRefreshScheduled = false

        self.progressButton.title = self.status
        nextProgressUpdate = Date(timeIntervalSinceNow: progressRefreshDelay)
    }

    func scheduleChartRefresh() {
        if !chartRefreshScheduled {
            self.perform(#selector(AppDelegate.refreshChart), with: nil, afterDelay: 0.1)
            chartRefreshScheduled = true
        }
    }

    func cancelChartRefresh() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(AppDelegate.refreshChart), object: nil)
        chartRefreshScheduled = false
    }

    func refreshChart() {
        cancelChartRefresh()
        let suite = self.selectedSuite ?? self.runner.suites[0]
        let results = runner.results(for: suite)
        let chart: Chart
        if amortized.value {
            chart = Chart(size: AppDelegate.imageSize, suite: suite, results: results, amortized: true)
        }
        else {
            chart = Chart(size: AppDelegate.imageSize, suite: suite, results: results,
                          sizeRange: 1 ..< (1 << 20),
                          timeRange: 1e-7 ..< 1000,
                          amortized: false)
        }
        let image = chart.image
        self.chartImageView.image = image
        self.chartImageView.name = "\(suite.title) - \(benchmarksPopUpButton.title)"
    }

    @IBAction func newDocument(_ sender: AnyObject) {
        runner.reset()
        refreshChart()
    }

    func scheduleSave() {
        if !saveScheduled {
            self.perform(#selector(AppDelegate.save), with: nil, afterDelay: 30.0)
            saveScheduled = true
        }
    }

    func cancelSave() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(AppDelegate.save), object: nil)
        saveScheduled = false
    }

    func save() {
        do {
            cancelSave()
            try runner.save()
            window.isDocumentEdited = false
        }
        catch {
            // Ignore for now
        }
    }

    @IBAction func saveDocument(_ sender: AnyObject) {
        self.save()
    }

    func start() {
        guard self.runner.state == .idle else { return }
        let suite = self.selectedSuite ?? self.runner.suites[0]
        self.runButton.image = #imageLiteral(resourceName: "StopTemplate")
        self.startMenuItem.title = "Stop Running"
        self.status = "Running \(suite.title)"
        self.runner.start(suite: suite, randomized: randomizeInputs.value)
    }

    func stop() {
        guard self.runner.state == .running || self.waitingForParamsChange else { return }
        self.runButton.isEnabled = false
        self.startMenuItem.isEnabled = false
        self.status = "Stopping..."
        if self.runner.state == .running {
            self.runner.stop()
        }
    }

    @IBAction func run(_ sender: AnyObject) {
        switch self.runner.state {
        case .idle:
            self.start()
        case .running:
            self.stop()
        case .stopping:
            // Do nothing
            break
        }
    }

    func refreshRunnerParams() {
        if self.runner.state == .running {
            self.waitingForParamsChange = true
            self.runner.stop()
        }
        else {
            DispatchQueue.main.async {
                self.save()
            }
        }
    }

    @IBAction func didSelectSuite(_ sender: NSMenuItem) {
        let index = suitePopUpButton.indexOfSelectedItem
        selectedSuite = runner.suites[index == -1 ? 0 : index]
    }

    @IBAction func selectNextSuite(_ sender: AnyObject?) {
        let suite = self.selectedSuite ?? self.runner.suites[0]
        let index = self.runner.suites.index(where: { $0.title == suite.title }) ?? 0
        self.selectedSuite = self.runner.suites[(index + 1) % self.runner.suites.count]
    }

    @IBAction func selectPreviousSuite(_ sender: AnyObject?) {
        let suite = self.selectedSuite ?? self.runner.suites[0]
        let index = self.runner.suites.index(where: { $0.title == suite.title }) ?? 0
        self.selectedSuite = index == 0 ? self.runner.suites.last! : self.runner.suites[index - 1]
    }

    @IBAction func didSelectMaxSize(_ sender: NSMenuItem) {
        let i = sender.tag
        let suite = self.selectedSuite ?? self.runner.suites[0]
        runner.results(for: suite).scaleRange = 0 ... i
        refreshMaxScale()
        refreshRunnerParams()
    }

    func refreshMaxScale() {
        let suite = self.selectedSuite ?? self.runner.suites[0]
        let results = self.runner.results(for: suite)
        let maxScale = results.scaleRange.upperBound
        if let item = self.maxSizePopUpButton.menu?.items.first(where: { $0.tag == maxScale }) {
            if self.maxSizePopUpButton.selectedItem !== item {
                self.maxSizePopUpButton.select(item)
            }
        }
        else {
            self.maxSizePopUpButton.select(nil)
        }
    }

    func refreshBenchmarks() {
        let suite = self.selectedSuite ?? self.runner.suites[0]
        let results = self.runner.results(for: suite)
        let selected = results.selectedBenchmarks.isDisjoint(with: results.selectedBenchmarks)
            ? Set(suite.benchmarkTitles)
            : results.selectedBenchmarks.intersection(suite.benchmarkTitles)

        let title: String
        switch selected.count {
        case 0:
            fatalError()
        case 1:
            title = selected.first!
        case suite.benchmarkTitles.count:
            title = "All Benchmarks"
        default:
            title = "\(selected.count) Benchmarks"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "All Benchmarks", action: #selector(AppDelegate.selectAllBenchmarks(_:)), keyEquivalent: "a")
        let submenu = NSMenu()
        let submenuItem = NSMenuItem(title: "Just One", action: nil, keyEquivalent: "")
        submenuItem.submenu = submenu
        menu.addItem(submenuItem)
        menu.addItem(NSMenuItem.separator())

        for title in suite.benchmarkTitles {
            let item = NSMenuItem(title: title, action: #selector(AppDelegate.toggleBenchmark(_:)), keyEquivalent: "")
            item.state = selected.contains(title) ? NSOnState : NSOffState
            menu.addItem(item)

            submenu.addItem(withTitle: title, action: #selector(AppDelegate.selectBenchmark(_:)), keyEquivalent: "")
        }
        self.benchmarksPopUpButton.menu = menu
    }

    @IBAction func selectAllBenchmarks(_ sender: AnyObject) {
        let suite = self.selectedSuite ?? self.runner.suites[0]
        let results = self.runner.results(for: suite)
        results.selectedBenchmarks = []
        refreshBenchmarks()
        refreshChart()
        refreshRunnerParams()
    }

    @IBAction func toggleBenchmark(_ sender: NSMenuItem) {
        let suite = self.selectedSuite ?? self.runner.suites[0]
        let results = self.runner.results(for: suite)
        var selected = results.selectedBenchmarks.isDisjoint(with: results.selectedBenchmarks)
            ? Set(suite.benchmarkTitles)
            : results.selectedBenchmarks.intersection(suite.benchmarkTitles)
        if selected.contains(sender.title) {
            selected.remove(sender.title)
        }
        else {
            selected.insert(sender.title)
        }
        if selected.isEmpty || selected.count == suite.benchmarkTitles.count {
            results.selectedBenchmarks = []
        }
        else {
            results.selectedBenchmarks = selected
        }
        refreshBenchmarks()
        refreshChart()
        refreshRunnerParams()
    }

    @IBAction func selectBenchmark(_ sender: NSMenuItem) {
        let title = sender.title
        let suite = self.selectedSuite ?? self.runner.suites[0]
        guard suite.benchmarkTitles.contains(title) else { return }
        let results = self.runner.results(for: suite)
        results.selectedBenchmarks = [title]
        refreshBenchmarks()
        refreshChart()
        refreshRunnerParams()
    }

    @IBAction func increaseMaxScale(_ sender: AnyObject) {
        let suite = self.selectedSuite ?? self.runner.suites[0]
        let results = self.runner.results(for: suite)
        results.scaleRange = 0 ... min(maximumScale, results.scaleRange.upperBound + 1)
        refreshMaxScale()
        refreshRunnerParams()
    }

    @IBAction func decreaseMaxScale(_ sender: AnyObject) {
        let suite = self.selectedSuite ?? self.runner.suites[0]
        let results = self.runner.results(for: suite)
        results.scaleRange = 0 ... max(minimumScale, results.scaleRange.upperBound - 1)
        refreshMaxScale()
        refreshRunnerParams()
    }
}