//
//  GeneralTabController.swift
//  tabTestStoryboards
//
//  Created by Noah Nübling on 23.07.21.
//

import Cocoa
import ReactiveSwift
import ReactiveCocoa

class GeneralTabController: NSViewController {
    
    /// Convenience
    var enabled: MutableProperty<Bool> { State.shared.appIsEnabled }
    
    /// Config
    var showInMenubar: MutableProperty<Bool> = MutableProperty(false)
    var checkForUpdates: MutableProperty<Bool> = MutableProperty(false)
    var getBetaVersions: MutableProperty<Bool> = MutableProperty(false)
    
    /// Outlets
    
    @IBOutlet var mainView: NSView!
    
    @IBOutlet weak var masterStack: CollapsingStackView!
    
    @IBOutlet weak var enableToggle: NSControl!
    
    @IBOutlet weak var menuBarToggle: NSButton!
    
    @IBOutlet weak var updatesToggle: NSButton!
    @IBOutlet weak var betaToggle: NSButton!
    
    @IBOutlet weak var mainHidableSection: CollapsingStackView!
    @IBOutlet weak var updatesExtraSection: NSView!
    
    
    @IBOutlet weak var enabledHint: NSTextField!
    @IBOutlet weak var updatesHint: NSTextField!
    

    override func viewDidLoad() {
        super.viewDidLoad()
        
        /// Load data
        enabled.value = false
        showInMenubar.value = false
        checkForUpdates.value = false
        getBetaVersions.value = false
        
        /// Replace enable checkBox with NSSwitch on newer macOS versions
        if #available(macOS 10.15, *) {

            let state = enableToggle.value(forKey: "state")

            let switchView = NSSwitch()
            
            enableToggle.superview?.replaceSubview(enableToggle, with: switchView)
            self.enableToggle = switchView

            self.enableToggle.setValue(state, forKey: "state")
            
            switchView.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        
        /// Declare signals
        
        /// UI <-> data bindings
        
        enabled <~ enableToggle.reactive.boolValues
        showInMenubar <~ menuBarToggle.reactive.boolValues
        checkForUpdates <~ updatesToggle.reactive.boolValues
        getBetaVersions <~ betaToggle.reactive.boolValues
        
        enableToggle.reactive.boolValue <~ enabled
        menuBarToggle.reactive.boolValue <~ showInMenubar
        updatesToggle.reactive.boolValue <~ checkForUpdates
        betaToggle.reactive.boolValue <~ getBetaVersions
        
        mainHidableSection.reactive.isCollapsed <~ enabled.negate()
        updatesExtraSection.reactive.isCollapsed <~ checkForUpdates.negate()
        
        /// Labels
        
        enabledHint.stringValue = NSLocalizedString("Mac Mouse Fix will stay enabled after you\nclose it", comment: "")
        updatesHint.stringValue = NSLocalizedString("You'll see new updates when you open this window", comment: "")
        
//        updatesHint.reactiveAnimator(type: .fade).stringValue <~ checkForUpdates.map { checkUpdates in
//            return checkUpdates ?
//                NSLocalizedString("You'll see new updates when you open this window", comment: "")
//                : NSLocalizedString("You won't see updates", comment: "")
//        }
        
    }
}
