//
// --------------------------------------------------------------------------
// HelperServices.m
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2019
// Licensed under MIT
// --------------------------------------------------------------------------
//

/// Notes on availability
///     HelperServices uses a new API for registering the Helper as UserAgent under macOS 13 Ventura. It's called `SMAppService`. It's not available pre-Ventura. To handle this we use Apple's availability APIs.
///     Unfortunately there have been problems with the availability APIs. See https://github.com/noah-nuebling/mac-mouse-fix/issues/241.
///     Below you can find my notes / stream of consciousness on trying to figure this out.
///
///     __General confusion__: Apple uses `API_AVAILABLE()` on ObjC and Swift interfaces . But we want to mark a static C function implementation for availability. This isn't documented anywhere I could find. But it does successfully give a warning when you try to call the C function outside an `if @available` block, and it let's you use `SMAppService` inside the marked function without an `if @available` block. So it really lets you think that it's not running the code pre Ventura and that everything is fine. Yet, apparently it tries to link the unavailable code on older versions and then crashes.
///     Sidenote: Not sure where the underscore variant `__API_AVAILABLE` comes from.
///     __Summary of Problem__: Users that don't use Ventura have experienced crashes that happen while trying to link `SMAppService`. (Which isn't available pre-Ventura).
///     __Ideas for what's the problem__: 1. `__` underscores variant of the macro shouldn't be used and breaks things. 2. Availability macro doesn't work properly on C functions. 3. We STILL need to wrap code inside the `API_AVAILABLE`d function with `if @available` blocks. (Even though Xcode gives no warning against this)
///     -> It's hard to know because I can't test older versions right now.
///     Edit: Looked at `__API_AVAILABLE` and `API_AVAILABLE`, and I think they are probably identical.
///     __Game plan__: Fix all the possible reasons we could come up with: 1. Use non-underscore variant. 2. Make all the unavailable function into objc methods (and make sure they are marked in the header too, if they appear there) 3. wrap everything in `if @available` blocks. Bing bam boom.

///     Upate 14.08.2022 Still crashes for the dude. Made another change: All mentions of macOS 11, 12, 13 have been replaced with 11.0, 12.0, 13.0. Because all the examples on the internet write it like that. Let's see if that helps. Edit: That fixed it! See https://github.com/noah-nuebling/mac-mouse-fix/issues/241

#import <AppKit/AppKit.h>
#import "HelperServices.h"
#import "Constants.h"
#import "Locator.h"
#import "SharedUtility.h"
#import <ServiceManagement/ServiceManagement.h>
#import <sys/sysctl.h>
#import <sys/types.h>

@implementation HelperServices

#pragma mark - Main interface

+ (BOOL)helperIsActive {
    if (@available(macos 13.0, *)) {
        return [self helperIsActive_SM];
    } else {
        return helperIsActive_PList();
    }
}

+ (void)enableHelperAsUserAgent:(BOOL)enable onComplete:(void (^ _Nullable)(NSError * _Nullable error))onComplete {
    
    /// Register/unregister the helper as a User Agent with launchd so it runs in the background - also launches/terminates helper
    
    if (@available(macos 13.0, *)) {
        
        /// Disable and clean up legacy versions
        [self runPreviousVersionCleanup];
        [self removeHelperFromLaunchd];
        removeLaunchdPlist();
        
        /// Call core
        ///    Do this on some global queue. Xcode complains if you do this on mainThread because it can lead to unresponsive UI.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            NSError *error = [self enableHelper_SM:enable];
            if (onComplete != nil) onComplete(error);
        });
        
    } else {
        enableHelper_PList(enable);
        if (onComplete != nil) onComplete(nil);
    }
}

+ (void)killAllHelpers {
    
    /// The updated helper application will subsequently be launched by launchd due to the keepAlive attribute in Mac Mouse Fix Helper's launchd.plist
    /// This is untested but it's copied over from the old Updating mechanism, so I trust that it works in this context, too.
    
    BOOL helperNeutralized = NO;
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:kMFBundleIDHelper]) {
        if ([app.bundleURL isEqualTo: Locator.helperOriginalBundle.bundleURL]) {
            [app terminate];
            helperNeutralized = YES;
            break;
        }
    }
    
    if (helperNeutralized) {
        NSLog(@"Helper has been neutralized");
    } else {
        NSLog(@"No helper found to neutralize");
    }
}

+ (void)restartHelper {
    
    /// If this function is called before `possibleRestartTime` it will freeze until that time
    
    NSString *serviceTarget = stringf(@"gui/%u/%@", geteuid(), [self launchdID]);
    [SharedUtility launchCLT:[NSURL fileURLWithPath:kMFLaunchctlPath] withArguments:@[@"kickstart", @"-k", serviceTarget] error:nil];
}

+ (NSDate *)possibleRestartTime {
    
    /// Launchd allows at most 1 launch per 10 seconds.
    ///     This method returns the earliest possible restart of the helper.
    
    /// Get helper startTime
    /// Src: https://stackoverflow.com/a/40677286/10601702
    
    NSRunningApplication *helper = [NSRunningApplication runningApplicationsWithBundleIdentifier:Locator.helperBundle.bundleIdentifier][0];
    pid_t pid = helper.processIdentifier;
    
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc proc;
    size_t size = sizeof(proc);
    sysctl(mib, 4, &proc, &size, NULL, 0);
    
    NSDate *startTime = [NSDate dateWithTimeIntervalSince1970:proc.kp_proc.p_starttime.tv_sec];
    
    /// Get earliest possible restart time
    
    NSDate *tenSecs = [startTime dateByAddingTimeInterval:10];
    NSDate *now = [NSDate date];
    NSDate *possibleRestartTime = [now laterDate:tenSecs];
    
    /// Return
    
    return possibleRestartTime;
}

+ (NSString *)launchHelperInstanceWithMessage:(NSString *)message {
    
    /// Launches a new instance of helper in special mode where it processes the `message` and then quits immediately.
    ///     This function will wait until the helper has quit
    
    /// Define args for the `open` CLT
    ///     `-W` waits until the app has quit, `-n` spawns a new instance of the app, `-a` specifies the application to open, `--args` specifies the args to pass to the application.
    NSArray *args = @[@"-W", @"-n", @"-a", Locator.helperBundle.bundlePath, @"--args", message];
    
    /// Launch the tool
    ///     And wait
    ///     Should probably do some error handing here
    NSString *response = [SharedUtility launchCLT:[NSURL fileURLWithPath:kMFOpenCLTPath] withArguments:args error:nil];
    
    /// Return
    return response;
}


#pragma mark - Core

+ (NSString *)launchdID {
    if (@available(macos 13.0, *)) {
        return kMFLaunchdHelperIdentifierSM;
    } else {
        return kMFLaunchdHelperIdentifier;
    }
}

+ (BOOL)helperIsActive_SM API_AVAILABLE(macos(13.0)) {
    
    if (@available(macos 13.0, *)) {
        
        SMAppService *service = [SMAppService agentServiceWithPlistName:@"sm_launchd.plist"];
        BOOL result = service.status == SMAppServiceStatusEnabled;
        
#if DEBUG
        if (result) {
            NSLog(@"Helper found to be active");
        } else {
            NSLog(@"Helper found to be inactive. Status: %ld", (long)service.status);
        }
#endif
        return result;
    } else {
        /// Not running macOS 13
        ///     This can never happen. Just crashing here so the compiler doesn't complain about missing returns.
        exit(1);
    }
}

static BOOL helperIsActive_PList() {
    
    /// Get info from launchd
    NSString *launchctlOutput = [HelperServices helperInfoFromLaunchd];
    
    /// Analyze info
    
    /// Check if label exists. This should always be found if the helper is registered with launchd. Or equavalently, if the output isn't "Could not find service "mouse.fix.helper" in domain for port"
    NSString *labelSearchString = stringf(@"\"Label\" = \"%@\";", kMFLaunchdHelperIdentifier);
    BOOL labelFound = [launchctlOutput rangeOfString: labelSearchString].location != NSNotFound;
    
    /// Check exit status. Not sure if useful
    BOOL exitStatusIsZero = [launchctlOutput rangeOfString: @"\"LastExitStatus\" = 0;"].location != NSNotFound;
    
    if (HelperServices.strangeHelperIsRegisteredWithLaunchd) {
        NSLog(@"Found helper running somewhere else.");
        return NO;
    }
    
    if (labelFound && exitStatusIsZero) { /// Why check for exit status here?
        NSLog(@"MOUSE REMAPOR FOUNDD AND ACTIVE");
        return YES;
    } else {
        NSLog(@"Helper is not active");
        return NO;
    }
}

+ (NSError *_Nullable)enableHelper_SM:(BOOL)enable API_AVAILABLE(macos(13.0)) {
    
    if (@available(macos 13.0, *)) {
            
        /// Create error
        
        NSError *error = nil;

        /// Do the core (un)registering
        ///     `loginItemServiceWithIdentifier:` would be easiest but it breaks with multiple copies of the app installed. Also, it doesn't allow for setting niceness and other stuff. So using an agent is better.
        
        SMAppService *service = [SMAppService agentServiceWithPlistName:@"sm_launchd.plist"];
        if (enable) {
            BOOL success = [service registerAndReturnError:&error];
            if (!success){
                NSLog(@"Failed to register Helper with error: %@", error);
            } else {
                NSLog(@"Registered Helper!");
            }
        } else {
            BOOL success = [service unregisterAndReturnError:&error];
            if (!success){
                NSLog(@"Failed to UNregister Helper with error: %@", error);
            } else {
                NSLog(@"Unregistered Helper.");
            }
        }
        
        return error;
    } /// End `if @available`
    
    exit(1);
}

static void enableHelper_PList(BOOL enable) {
    
    /// This is the main function for the 'old method' where we were manually managing a plist file. Under Ventura we switched to a new framework
    
    /// Repair/generate launchdPlist so that the following code works for sure
    [HelperServices repairLaunchdPlist];
    
    /// If an old version of Mac Mouse Fix is still running and stuff, clean that up to prevent issues
    [HelperServices runPreviousVersionCleanup];
    
    /**
     Sometimes there's a weird bug where the main app won't recognize the helper as enabled even though it is. The code down below for enabling will then fail, when the user tries to check the enable checkbox.
     So we're removing the helper from launchd before trying to enable to hopefully fix this. Edit: seems to fix it!
     I'm pretty sure that if we didn't check for `launchdPathIsBundlePath` in `strangeHelperIsRegisteredWithLaunchd` this issue wouldn't have occured and we wouldn't need this workaround. But I'm not sure anymore why we do that so it's not smart to remove it.
     Edit: I think the specific issue I saw only happens when there are two instances of MMF open at the same time.
     */
    if (enable) {
        [HelperServices removeHelperFromLaunchd];
        
        /// Any Mac Mouse Fix Helper processes that were started by launchd should have been quit by now. But if there are Helpers which weren't started by launchd they will still be running which causes problems. Terminate them now.
        [HelperServices terminateOtherHelperInstances];
    }
    
    /// Prepare strings for NSTask
    
    /// Path for the executable of the launchctl command-line-tool, which we use to control launchd
    
    /// Prepare arguments for the launchctl command-line-tool
    if (@available(macOS 10.13, *)) {
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath: kMFLaunchctlPath];
        NSString *GUIDomainArgument = [NSString stringWithFormat:@"gui/%d", geteuid()];
        NSString *OnOffArgument = (enable) ? @"bootstrap": @"bootout";
        NSString *launchdPlistPathArgument = Locator.launchdPlistURL.path;
        task.arguments = @[OnOffArgument, GUIDomainArgument, launchdPlistPathArgument];
        NSPipe *pipe = NSPipe.pipe;
        task.standardError = pipe;
        task.standardOutput = pipe;
        NSError *error;
        task.terminationHandler = ^(NSTask *task) {
            if (enable == NO) { /// Cleanup (delete launchdPlist) file after were done // We can't clean up immediately cause then launchctl will fail
                removeLaunchdPlist();
            }
            NSLog(@"launchctl terminated with stdout/stderr: %@, error: %@", [NSString.alloc initWithData:pipe.fileHandleForReading.readDataToEndOfFile encoding:NSUTF8StringEncoding], error);
        };
        [task launchAndReturnError:&error];
        
    } else { /// Fallback on earlier versions
        NSString *OnOffArgumentOld = (enable) ? @"load": @"unload";
        [NSTask launchedTaskWithLaunchPath: kMFLaunchctlPath arguments: @[OnOffArgumentOld, Locator.launchdPlistURL.path]]; /// Can't clean up here easily cause there's no termination handler
    }
}

static void removeLaunchdPlist() {
    NSError *error;
    [NSFileManager.defaultManager removeItemAtURL:Locator.launchdPlistURL error:&error];
    if (error != nil) {
        NSLog(@"Failed to delete launchd.plist file. The helper will likely be re-enabled on startup. Delete the file at \"%@\" to prevent this.", Locator.launchdPlistURL.path); /// TODO: Make this a DDLogError() statement
    }
}

+ (void)repairLaunchdPlist {
    /// What this does:
    
    /// Get path of executable of helper app
    /// Check
    /// - If the "User/Library/LaunchAgents/mouse.fix.helper.plist" useragent config file  (aka launchdPlist) exists
    ///     - This specific path is deprecated, since MMF is an app not a prefpane now
    /// - If the Launch Agents Folder exists
    /// - If the exectuable path within the plist file is correct
    /// If not:
    /// Create correct file based on "default_launchd.plist" and the helpers exectuablePath
    /// Write correct file to "User/Library/LaunchAgents"
    
    @autoreleasepool {
        /// Do we need an autoreleasepool here?
        /// -> No. Remove this.
        /// I just read up on it. You only need to manually use `autoreleasepool`s for optimization and some edge cases
        /// Here's my understanding. In normal scenarios, Cocoa objects are automatically sent autorelease messages when they go out of scope. Then, on the next iteration of the runloop, all objects that were sent autorelease messages will be sent release messges. Which will in turn cause their reference counts to drop, which will cause them to be deallocated when that reaches 0. When you use a manual autoreleasepool, then the autoreleased Cocoa objects will be sent release messages after the autoreleasepool block ends, and not only at the next runloop iteration. That's all it does in this scenario.
        /// When to use autoreleasepool: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/MemoryMgmt/Articles/mmAutoreleasePools.html
        /// When autoreleased objects are sent release messages: https://stackoverflow.com/questions/673372/when-does-autorelease-actually-cause-a-release-in-cocoa-touch
        
        NSLog(@"Repairing User Agent Config File");
        
        /// Declare error
        NSError *error;
        
        /// Get helper executable path
        NSBundle *helperBundle = Locator.helperBundle;
        NSBundle *mainAppBundle = Locator.mainAppBundle;
        NSString *helperExecutablePath = helperBundle.executablePath;
        
        /// Get path to launch agent config file (aka launchdPlist)
        NSString *launchdPlist_path = Locator.launchdPlistURL.path;
        
        /// Create file manager
        
        NSFileManager *fileManager = [[NSFileManager alloc] init];
        
        /// Check if launchPlist file exists
        
        BOOL launchdPlist_exists = [fileManager fileExistsAtPath: launchdPlist_path isDirectory: nil];
        
        /// Check if executable path is correct
        
        BOOL launchdPlist_executablePathIsCorrect = YES;
        
        if (launchdPlist_exists) {
            
            /// Load data from launch agent config file into a dictionary
            NSData *launchdPlist_data = [NSData dataWithContentsOfFile:launchdPlist_path];
            NSDictionary *launchdPlist_dict = [NSPropertyListSerialization propertyListWithData:launchdPlist_data options:NSPropertyListImmutable format:0 error:nil];
            
            /// Check if the executable path inside the config file is correct, if not, set flag to false
            NSString *helperExecutablePathFromFile = [launchdPlist_dict objectForKey: @"Program"];
            if ( [helperExecutablePath isEqualToString: helperExecutablePathFromFile] == NO ) {
                launchdPlist_executablePathIsCorrect = NO;
            }
            
            /// Debug
//            NSLog(@"objectForKey: %@", OBJForKey);
//            NSLog(@"helperExecutablePath: %@", helperExecutablePath);
//            NSLog(@"OBJ == Path: %d", OBJForKey isEqualToString: helperExecutablePath);
        }
        
        /// Log
        
        NSLog(@"launchdPlistExists %hhd, launchdPlistIsCorrect: %hhd", launchdPlist_exists,launchdPlist_executablePathIsCorrect);
        
        
        if ((launchdPlist_exists == FALSE) || (launchdPlist_executablePathIsCorrect == FALSE)) {
            /// The config file doesn't exist, or the executable path within it is not correct
            ///  -> Acutally repair stuff
            
            NSLog(@"repairing file...");
            
            /// Check if "User/Library/LaunchAgents" folder exists, if not, create it
            
            NSString *launchAgentsFolderPath = [launchdPlist_path stringByDeletingLastPathComponent];
            
            BOOL launchAgentsFolderExists = [fileManager fileExistsAtPath:launchAgentsFolderPath isDirectory:nil];
            
            if (launchAgentsFolderExists == NO) {
                
                NSLog(@"LaunchAgents folder doesn't exist");
                NSError *error;
                
                /// Create LaunchAgents folder
                
                error = nil;
                [fileManager createDirectoryAtPath:launchAgentsFolderPath withIntermediateDirectories:FALSE attributes:nil error:&error];
                if (error == nil) {
                    NSLog(@"LaunchAgents Folder Created");
                } else if (error.code == NSFileWriteNoPermissionError) {
                    NSLog(@"Lacking permission to create LaunchAgents folder. Error: %@", error);
                } else {
                    NSLog(@"Error creating LaunchAgents Folder: %@", error);
                }
            }
            
            /// Repair permissions of LaunchAgents folder if it's not writable
            
            error = makeWritable(launchAgentsFolderPath);
            if (error) {
                NSLog(@"Failed to make LaunchAgents folder writable. Error: %@", error);
            }
            
            /// Repair the contents of the launchdPlist file

            /// Read contents of default_launchd.plist (aka default-launch-agent-config-file or defaultLAConfigFile) into a dictionary
            
            error = nil;
            
            NSString *defaultLaunchdPlist_path = [mainAppBundle pathForResource:@"default_launchd" ofType:@"plist"];
            NSData *defaultlaunchdPlist_data = [NSData dataWithContentsOfFile:defaultLaunchdPlist_path];
            // TODO: This just crashed the app with "Exception: "data parameter is nil". It says that that launchdPlistExists = NO.
            // I was running Mac Mouse Fix Helper standalone for debugging, not embedded in the main app
            NSMutableDictionary *newlaunchdPlist_dict = [NSPropertyListSerialization propertyListWithData:defaultlaunchdPlist_data options:NSPropertyListMutableContainersAndLeaves format:nil error:&error];
            
            /// Set the executable path to the correct value
            [newlaunchdPlist_dict setValue: helperExecutablePath forKey:@"Program"];
            
            /// Get NSData from newLaunchdPlist dict
            NSData *newLaunchdPlist_data = [NSPropertyListSerialization dataWithPropertyList:newlaunchdPlist_dict format:NSPropertyListXMLFormat_v1_0 options:0 error:&error];
            NSAssert(error == nil, @"Failed to create NSData from new launchdPlist dict");
            
            /// Write new newLaunchdPlist data to file
            [newLaunchdPlist_data writeToFile:launchdPlist_path options:NSDataWritingAtomic error:&error];
            
            if (error != nil) {
                NSLog(@"repairUserAgentConfigFile() -- Data Serialization Error: %@", error);
            }
        } else {
            NSLog(@"Nothing to repair");
        }
    }
    
}

static NSError *makeWritable(NSString *itemPath) {
    /**
     
     Helper function for + repairLaunchdPlist
     Changes permissions of the item at filePath to allow writing by the user to that item
     
     __Motivation__
     - This is intended to be used by + repairLaunchdPlist to unlock the LaunchAgents folder so we can write our LaunchdPlist into it.
     - For some reason, many users have had troubles enabling Mac Mouse Fix recently. Many of these troubles turned out to be due to the LaunchAgents folder having it's permissions set to 'read only'. This function can be used to fix that.
        - See for example Issue [#54](https://github.com/noah-nuebling/mac-mouse-fix/issues/54)
        - There was also another GH issue where the user orignially figured out that permissions were the problem which prompted me to add better logging. But I'm writing this function much later. So I can't remember which GH Issue that was. Props to that user anyways.
    
     __Notes__
     - I really hope this doesn't break anything. Changing permissions in the file system feels somewhat dangerous.
     - Also it might be a good idea to ask the user if they want the permissions to be changed, but 99.9% of users won't even understand what they are deciding about, and it would be a lot of work to present this in a good way. So I think this should be fine.
     */
    
    /// Get fileManager
    
    NSFileManager *fileManager = NSFileManager.defaultManager;
    
    /// Check if file at filePath is writable
    
    if (![fileManager isWritableFileAtPath:itemPath]) {
        /// File is not writable
        
        /// Log
        
        NSLog(@"File at %@ is not writable. Attempting to change permissions.", itemPath);
        
        /// Declare error
        
        NSError *error;
        
        /// Get file attributes
        
        error = nil;
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:itemPath error:&error];
        if (error) return error;
        
        /// Get old permissions from file attributes
        
        NSUInteger oldPermissions = attributes.filePosixPermissions;
        
        /// Create new permissions
        
        NSUInteger newPermissions = oldPermissions | S_IWUSR;
        /// ^ Add write permission for user. See `man 2 chmod` for more info
            
        /// Set new permissions to file
            
        error = nil;
        [fileManager setAttributes:@{
            NSFilePosixPermissions: @(newPermissions)
        } ofItemAtPath:itemPath error:&error];
        
        if (error) {
            return error;
        }
        
        /// Debug
        
        NSLog(@"Changed permissions of %@ from %@ to %@", itemPath,  [SharedUtility binaryRepresentation:(int)oldPermissions], [SharedUtility binaryRepresentation:(int)newPermissions]);
        /// ^ Binary representation doesn't really help. This is almost impossible to parse visually.
    }
    
    return nil;
}

+ (NSString *)helperInfoFromLaunchd {
    
    /// Using NSTask to ask launchd about helper status
    NSURL *launchctlURL = [NSURL fileURLWithPath: kMFLaunchctlPath];
    NSString * launchctlOutput = [SharedUtility launchCLT:launchctlURL withArguments:@[@"list", kMFLaunchdHelperIdentifier] error:nil];
    return launchctlOutput;
}

#pragma mark - Clean up legacy stuff

+ (void)runPreviousVersionCleanup {
    
    NSLog(@"Cleaning up stuff from previous versions");
    
    if (self.strangeHelperIsRegisteredWithLaunchd) {
        [self removeHelperFromLaunchd];
    }
    
    [self removePrefpaneLaunchdPlist];
    /// ^ Could also do this in the if block but users have been having some weirdd issues after upgrading to the app version and I don't know why. I feel like this might make things slightly more robust.
}

/// Check if helper is registered with launchd from some other location
+ (BOOL)strangeHelperIsRegisteredWithLaunchd {
    
    NSString *launchdPath = [self helperExecutablePathFromLaunchd];
    BOOL launchdPathExists = launchdPath.length != 0;
    
    BOOL launchdPathIsBundlePath = [Locator.helperBundle.executablePath isEqual:launchdPath];
    
    if (!launchdPathIsBundlePath && launchdPathExists) {
        
        NSLog(@"Strange helper: found at: %@ \nbundleExecutable at: %@", launchdPath, Locator.helperBundle.executablePath);
        return YES;
    }
    
    NSLog(@"Strange Helper: not found");
    
    return NO;
}

+ (void)terminateOtherHelperInstances {
    /// Terminate any other running instances of the app
    /// Only call this after after removing the Helper from launchd
    /// This only works to terminate instances of the Helper which weren't started by launchd.
    /// Launchd-started instances will immediately be restarted after they are terminated
    /// Mac Mouse Fix Accomplice does something similar to this in update()
    
    NSLog(@"Terminating other Helper instances");
    
    NSArray<NSRunningApplication *> *instances = [NSRunningApplication runningApplicationsWithBundleIdentifier:kMFBundleIDHelper];
    
    NSLog(@"%lu other running Helper instances found", (unsigned long)instances.count);
        
    for (NSRunningApplication *instance in instances) {
        [instance terminate]; /// Consider using forceTerminate instead
    }
    
}

+ (void)removeHelperFromLaunchd {
    
    /// Remove service from launchd
    /// Notes:
    /// - From my testing this does the same as the `bootout` command, but it doesn't rely on a valid launchd.plist file to exist in the library, so it should be more robust.
    /// - The removed service will be quit immediately but will be restarted on the next boot. Pre-SMAppService you can prevent start on next boot by deleting the launchd.plist file. Post-SMAppService you need to unregister the service. Not sure if there are other ways.
    
    NSString *identifier = kMFLaunchdHelperIdentifier;
    
    NSLog(@"Removing service %@ from launchd", identifier);
    
    NSURL *launchctlURL = [NSURL fileURLWithPath:kMFLaunchctlPath];
    NSError *err;
    [SharedUtility launchCLT:launchctlURL withArguments:@[@"remove", identifier] error:&err];
    if (err != nil) {
        NSLog(@"Error removing service %@ from launchd: %@", identifier, err);
    }
    
    /// Wait until service is actually removed
    /// Notes:
    /// - Otherwise enabling while old helper is still enabled won't work under Mojave
    /// - TODO: I copied this over from MMF 3 but was hacky since MMF 2 is missing some previous improvements made to HelperServices in MMF 3. That's bad, we shouldn't have let HelperServices diverge like that between MMF 2 and 3! We should unify them again.
    
    int maxWaitCycles = 25;
    int i = 0;
    while (true) {
        
        NSString *launchctlOutput = [HelperServices helperInfoFromLaunchd];
        
        if ([launchctlOutput isEqual:@""]) break;
        if (i >= maxWaitCycles) break;
        
        i += 1;
    }
}

+ (void)removePrefpaneLaunchdPlist {
        
    /// Remove legacy launchd plist file if it exists
    /// The launchd plist file used to be at `~/Library/LaunchAgents/com.nuebling.mousefix.helper.plist` when the app was still a prefpane
    /// Now, with the app version, it's moved to `~/Library/LaunchAgents/com.nuebling.mac-mouse-fix.helper.plist`
    /// Having the old version still can lead to the old helper being started at startup, and I think other conflicts, too.
    
    NSLog(@"Removing legacy launchd plist");
    
    /// Find user library
    NSArray<NSString *> *libraryPaths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    assert(libraryPaths.count == 1);
    NSMutableString *libraryPath = libraryPaths.firstObject.mutableCopy;
    NSString *legacyLaunchdPlistPath = [libraryPath stringByAppendingPathComponent:@"LaunchAgents/com.nuebling.mousefix.helper.plist"];
    NSError *err;
    // Remove old file
    if ([NSFileManager.defaultManager fileExistsAtPath:legacyLaunchdPlistPath]) {
        [NSFileManager.defaultManager removeItemAtPath:legacyLaunchdPlistPath error:&err];
        if (err) {
            NSLog(@"Error while removing legacy launchd plist file: %@", err);
        }
    } else  {
        NSLog(@"No legacy launchd plist file found at: %@", legacyLaunchdPlistPath);
    }
}

+ (NSString *)helperExecutablePathFromLaunchd {
    
    // Using NSTask to ask launchd about helper status
    NSString * launchctlOutput = [self helperInfoFromLaunchd];
    
    NSString *executablePathRegEx = @"(?<=\"Program\" = \").*(?=\";)";
    //    NSRegularExpression executablePathRegEx =
    NSRange executablePathRange = [launchctlOutput rangeOfString:executablePathRegEx options:NSRegularExpressionSearch];
    if (executablePathRange.location == NSNotFound) return @"";
    NSString *executablePath = [launchctlOutput substringWithRange:executablePathRange];
    
    return executablePath;
}

#pragma mark - Documentation & other

/// Example output of the `launchctl list mouse.fix.helper` command

/*
 {
     "StandardOutPath" = "/dev/null";
     "LimitLoadToSessionType" = "Aqua";
     "StandardErrorPath" = "/dev/null";
     "MachServices" = {
         "com.nuebling.mac-mouse-fix.helper" = mach-port-object;
     };
     "Label" = "mouse.fix.helper";
     "OnDemand" = false;
     "LastExitStatus" = 0;
     "PID" = 709;
     "Program" = "/Applications/Mac Mouse Fix.app/Contents/Library/LoginItems/Mac Mouse Fix Helper.app/Contents/MacOS/Mac Mouse Fix Helper";
     "PerJobMachServices" = {
         "com.apple.tsm.portname" = mach-port-object;
         "com.apple.axserver" = mach-port-object;
     };
 };
 */

/// Old stuff

/*
 //    NSString *prefPaneSearchString = @"/PreferencePanes/Mouse Fix.prefPane/Contents/Library/LoginItems/Mouse Fix Helper.app/Contents/MacOS/Mouse Fix Helper";
 */

@end
