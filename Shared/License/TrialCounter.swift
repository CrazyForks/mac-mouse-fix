//
// --------------------------------------------------------------------------
// TrialCounter.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2022
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

/// Testing checklist
/// - `[x]` Increments daysOfUse using __normal scrolling__ after deleting lastUseDate
/// - `[x]` Increments daysOfUse using __modifiedScroll with kb mods__ after deleting lastUseDate
/// - `[x]` Increments daysOfUse using __modifiedScroll with button mods__ after deleting lastUseDate
/// - `[x]` Increments daysOfUse when using simple actions after deleting lastUseDate
///     - `[x]`  clicking
///     - `[x]` holding
///     - `[x]` clicking when a doubleClick action is set up
/// - `[x]` Increments daysOfUse when clicking and __dragging__ after deleting lastUseDate
/// - `[x]` Increments daysOfUse when scrolling after setting system to __new date__
/// - `[x]` Doesn't increment daysOfUse more than once if you __don't change the date__
/// - `[x]` Doesn't increment daysOfUse when you use mouse after you restart Mac Mouse Fix Helper without changing the date
/// - `[x]` Doesn't increment daysOfUse when you use mouse  after you restart the computer while MMF is enabled and without changing date
/// - `[x]` Increments daysOfUse when the __day changes__ without restarting the app
///     -> We tested this by setting the daily timer to 60 seconds. That successfully incremented the counter. Also tested by starting the helper before 00:00 and then using it after 00:00. That worked as well!

/// - `[x]` Doesn't increment daysOfUse when using Trackpad

import Cocoa
import CocoaLumberjackSwift


@objc class TrialCounter: NSObject { /// Not annotated with @MainActor since we want `handleUse` to be callable from different threads without overhead, and this doesn't have any `async` functions. (See discussion in `License/README.md`)
    
    /// Singleton
    @objc static let shared = TrialCounter()
    
    /// Vars
    private var daily: Timer
    @Atomic private var hasBeenUsedToday: Bool
    private var trialIsActive: Bool
    
    /// Init
    
    @objc static func load_Manual() {
        /// Need to use loadManual() because the initialization does network calls and is async. So we need initialization to be done way before handleUse() is called for the first time, because otherwise the trialIsActive and hasBeenUsedToday flags will be wrong.
        ///     -> Don't think this is a watertight protection against this race-condition. TODO: Think about: 1. How to prevent the race cond. 2. Whether the race cond is acceptable.
        let _ = TrialCounter.shared
    }
    @objc override init() {
        
        /// Garbage init
        daily = Timer()
        hasBeenUsedToday = false
        trialIsActive = false
        
        /// Init super
        super.init()
        
        /// Guard not running helper
        ///     We only want to run the daily timer once, not in both apps
        ///     But we still might want to use this class in main app to access `lastUseDate` and `daysOfUse`.
        ///     Feel like it might be problematic to expose this to mainApp.
        if !runningHelper() { return }
        
        /// Real init
            
        /// Start an async-context
        ///     Notes:
        ///     - Using priority .background because it makes sense?
        ///     - @MainActor so all Licensing code runs on the main-thread
        Task.init(priority: .background, operation: { @MainActor in assert(Thread.isMainThread)
            
            /// Check licensing state
            let licenseState = await GetLicenseState.get()
            
            if licenseState.isLicensed {
                
                /// Do nothing if licensed
                
            } else {
        
            let licenseConfig = await GetLicenseConfig.get()
            let trialState = GetTrialState.get(licenseConfig)
        
            if !trialState.trialIsActive {
                
                /// Not licensed and trial expired -> do nothing
                ///     In this case AccessibilityCheck.m will perform the lockDown, by calling `License.runCheckAndReact()`
                
            } else {
                
                /// Trial period is active!
                
                /// Set trialActive flag
                self.trialIsActive = true
                
                /// Init hasBeenUsedToday
                self.hasBeenUsedToday = false
                if let lastUseDate = TrialCounter.lastUseDate as? NSDate {
                    let now = Date.init(timeIntervalSinceNow: 0)
                    let a = Calendar.current.dateComponents([.day, .month, .year], from: lastUseDate as Date)
                    let b = Calendar.current.dateComponents([.day, .month, .year], from: now)
                    let isSameDay = a.day == b.day && a.month == b.month && a.year == b.year
                    if isSameDay {
                        self.hasBeenUsedToday = true
                    }
                }
                
                /// Init daily timer
                ///     Notes:
                ///     - Is fired at 00:00 on the next day, and in 24 hour periods after that. We could also just do 24 hour periods without making sure it's always fired at 00:00. But I think it's a little nicer and more consistent from a user experience standpoint to have it reset at 00:00.
                ///     - When the computer sleeps the timer is not fired. But it's fired after it wakes up. This shouldn't cause any problems.
                ///
                let secondsPerDay = 24*60*60
                let nextDay = Date(timeIntervalSinceNow: TimeInterval(secondsPerDay))
                let nextDayBreak = Calendar.current.startOfDay(for: nextDay)
                self.daily = Timer(fire: nextDayBreak, interval: TimeInterval(secondsPerDay), repeats: true) { timer in
                    DDLogInfo("Daily trial timer fired")
                    self.hasBeenUsedToday = false
                }
                
                /// Schedule daily timer
                ///     Not sure if .default or .common is better here. Default might be a little more efficicent but maybe it doesn't work in some cases?
                RunLoop.main.add(self.daily, forMode: .common)
                }
            }
        })
    }
    
    /// Vars
    /// Notes:
    /// - Storing the daysOfUse in SecureStorage so it doesn't get reset on uninstall by apps like AppCleaner by Freemacsoft.
    /// - At the time of writing, this is the ony part of TrialCounter.swift that is meant to be used by the mainApp.
    /// - At the time of writing, this is only accessed by License.swift. We will use this assumption when implementing the test flags like `FORCE_EXPIRED`. Accessing this from elsewhere might break the testing flags.
    
    @objc static var daysOfUse: Int {
        get {
            SecureStorage.get("License.trial.daysOfUse") as? Int ?? 0
        }
        set {
            SecureStorage.set("License.trial.daysOfUse", value: newValue)
        }
    }
    @objc static var lastUseDate: Date? {
        get {
            SecureStorage.get("License.trial.lastUseDate") as? Date
//            config("License.trial.lastUseDate") as? Date
        }
        set {
            SecureStorage.set("License.trial.lastUseDate", value: newValue! as NSObject)
//            setConfig("License.trial.lastUseDate", newValue! as NSObject)
//            commitConfig()
        }
    }
    
    /// Interface for Helper
    @objc func handleUse() {
        
        /// Debug
        DDLogDebug("TrialCounter.handleUse() called. trialIsActive: \(trialIsActive) | hasBeenUsedToday: \(hasBeenUsedToday) | lastUseDate: \(TrialCounter.lastUseDate ?? "<nil>") | daysOfUse: \(TrialCounter.daysOfUse)")
        
        /// Guard not running helper
        assert(runningHelper())
        
        /// Only react if trial is active
        if !trialIsActive { return }
        
        /// Only react to use once a day
        if hasBeenUsedToday { return }
        
        /// Start an async context
        /// Notes:
        /// - Old note: Dispatching to another queue here because there was an obscure concurrency crash when trying to debug something. This is not necessary for normal operation but it shouldn't hurt.
        ///     Update: (Oct 2024) now using `Task` instead of dispatch queue so we can use async/await
        /// - Update: Now using @MainActor so all licensing code runs on the mainthread. (Hope that won't bring back the 'obscure concurrency crash'?)
        
        Task.init(priority: .background, operation: { @MainActor in assert(Thread.isMainThread)
            
            /// Update state
            ///     Notes:
            ///     - Should we validate that the date has actually changed?
            ///     - (Oct 2024) This is shared mutable state. Can there be race conditions? How bad would their effect be? I saw we are already wrapping  self.hasBeenUsedToday with @Atomic, so we seem to have given this some thought, but it's not documented.
            self.hasBeenUsedToday = true
            TrialCounter.lastUseDate = Date(timeIntervalSinceNow: 0.0)
            TrialCounter.daysOfUse += 1
                
            /// Display UI & lock down helper if necessary
            ///     Note: In this code branch, we already know that the app is not licensed, that the trial is active, and that, therefore, we'll need to load the licenseConfig to obtain the trialDuration -> Perhaps we should pass this information into the called function? As it is, the called function has to re-gather this info independently.
            License.checkAndReact(triggeredByUser: false)
        })
    }
}
