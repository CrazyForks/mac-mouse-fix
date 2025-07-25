//
// --------------------------------------------------------------------------
// TrialSectionManager.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2022
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

///
/// I observed a bug [Mar 2025]
/// When app is not licensed, but the system region is set to a free country, then you start the app, and then hover over the trial section (which will show the 'activate license' text) *before* the free country message can load in –
///     then the UI will get stuck and the free country message never loads in. I've also seen the 'activate license' button itself get stuck in some weird, broken state, but not every time.
///

import Foundation
import CocoaLumberjackSwift

class TrialSectionManager {
    
    /// Vars
    
    var currentSection: TrialSection
    
    private var initialSection: TrialSection? = nil
    private var shouldShowAlternate = false
    private var queuedReplace: (() -> ())? = nil
    private var animationInterruptor: (() -> ())? = nil
    private var isReplacing = false
    
    /// Init
    
    init(_ initialSection: TrialSection) {
        
        /// Store initialSection
        self.initialSection = initialSection
        
        /// Fill out currentSection with garbage
        self.currentSection = initialSection
    }
    
    /// Start and stop
    
    func startManaging(licenseConfig: MFLicenseConfig, trialState: MFTrialState) {
        
        /// Make initialSection current
        showInitial(animate: false)
        
        /// Style intialSection
        
        /// Setup image
        let imageName = trialState.trialIsActive ? "calendar" : "calendar" /*"hourglass.tophalf.filled"*/
        
        if #available(macOS 11.0, *) {
            currentSection.imageView!.symbolConfiguration = .init(pointSize: 13, weight: .regular, scale: .large)
        }
        currentSection.imageView!.isHidden = false /// [Jul 2025] Context: Regex for `imageView.\.isHidden`
        currentSection.imageView!.image = Symbols.image(withSymbolName: imageName)
        
        /// Set string
        currentSection.textField!.attributedStringValue = LicenseUtility.trialCounterString(licenseConfig: licenseConfig, trialState: trialState)
        
        /// Set height
        ///     This wasn't necessary under Ventura but under Monterey the textField is too high otherwise
        ///     Edit: The problem is with a linebreak that our custom fallback markdown parser puts at the end! So using coolFittingSize or even fittingSize should be unnecessary.
        if let fittingHeight: CGFloat = currentSection.textField?.coolFittingSize().height {
            currentSection.textField?.heightAnchor.constraint(equalToConstant: fittingHeight).isActive = true
        }
        
    }
    
    func stopManaging() {
        animationInterruptor?()
        showInitial(animate: false)
    }
    
    /// Interface
    
    func showInitial(animate: Bool = true, hAnchor: MFHAnchor = .center) {
        
        /// This code is a little convoluted. showTrial and showActivate are almost copy-pasted, except for setting up in newSection in mouseEntered.
            
        let workload = {
            
            DDLogDebug("triall enter begin")
            
            if !self.shouldShowAlternate {
                self.finishReplace()
                return
            }
            self.shouldShowAlternate = false
            self.isReplacing = true
            
            let ogSection = self.currentSection
            let newSection = self.initialSection!
            
            assert(self.animationInterruptor == nil)
            
            self.animationInterruptor = ReplaceAnimations.animate(ogView: ogSection, replaceView: newSection, hAnchor: hAnchor, doAnimate: animate) {
                
                DDLogDebug("triall enter finish")
                
                self.animationInterruptor = nil
                
                self.currentSection = newSection
                
                self.finishReplace()
            }
        }
        
        if self.isReplacing {
            DDLogDebug("triall enter queue")
            self.queuedReplace = workload
        } else {
            workload()
        }

    }
    
    func showAlternate(animate: Bool = true, hAnchor: MFHAnchor = .center) {
        
        let workload = {
            
            do {
                
                DDLogDebug("triall exit begin")
                
                if self.shouldShowAlternate {
                    self.finishReplace()
                    return
                }
                self.shouldShowAlternate = true
                self.isReplacing = true
                
                let ogSection = self.currentSection
                let newSection = try SharedUtilitySwift.insecureDeepCopy(of: self.currentSection)
                
                ///
                /// Store original trialSection for easy restoration on mouseExit
                /// NOTES:
                /// - Why don't we store the initialSection when we start managing?
                /// - Why do we need to make a copy of the currentSection?
                
//                if self.initialSection == nil {
//                    self.initialSection = try SharedUtilitySwift.insecureDeepCopy(of: self.currentSection)
//                }
                
                ///
                /// Setup newSection
                ///
                
                /// Setup Image
                
                /// Create image
                let image = Symbols.image(withSymbolName: "lock.open")
                
                /// Configure image
                if #available(macOS 10.14, *) { newSection.imageView?.contentTintColor = .linkColor }
                if #available(macOS 11.0, *) { newSection.imageView?.symbolConfiguration = .init(pointSize: 13, weight: .medium, scale: .large) }
                
                /// Set image
                newSection.imageView?.isHidden = false
                newSection.imageView?.image = image
                
                /// Setup hyperlink
                ///     I've heard of the activate link not working for some people. I think I even experienced it, once. Perhaps, the app's ability to handle `macmousefix:` links breaks sometimes. Feels like it might be a bug/security feature in macOS?
                ///         Update: [Jul 2025] I think it was a bug with how we retrieved the ResizingTabWindow which we fixed a while ago.
                
                let linkTitle = NSLocalizedString("trial-notif.activate-license-button", comment: "First draft: Activate License")
                let linkAddress = "macmousefix:activate"
                let link = Hyperlink(title: linkTitle, url: linkAddress, alwaysTracking: true, leftPadding: 30)
                link?.font = NSFont.systemFont(ofSize: 13, weight: .regular)
                
                link?.translatesAutoresizingMaskIntoConstraints = false
                link?.heightAnchor.constraint(equalToConstant: link!.fittingSize.height).isActive = true
                link?.widthAnchor.constraint(equalToConstant: link!.fittingSize.width).isActive = true
                
                newSection.textField = link
                
                ///
                /// Animated replace
                ///
                
                assert(self.animationInterruptor == nil)
                
                self.animationInterruptor = ReplaceAnimations.animate(ogView: ogSection, replaceView: newSection, hAnchor: hAnchor, doAnimate: animate) {
                    
                    DDLogDebug("triall exit finish")
                    
                    self.animationInterruptor = nil
                    
                    self.currentSection = newSection
                    
                    self.finishReplace()
                }
            } catch {
                DDLogError("Failed to swap out trialSection on notification with error: \(error)")
                assert(false)
            }
        }
        
        if self.isReplacing {
            DDLogDebug("triall exit queue")
            self.queuedReplace = workload
        } else {
            workload()
        }
    }
    
    /// Helper
    
    fileprivate func finishReplace() {
        if let r = self.queuedReplace {
            self.queuedReplace = nil
            r()
        } else {
            self.isReplacing = false
        }
    }
}
