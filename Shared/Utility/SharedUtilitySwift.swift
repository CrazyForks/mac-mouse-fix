//
// --------------------------------------------------------------------------
// SharedUtilitySwift.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2022
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

import Cocoa
import CocoaLumberjackSwift

@objc class SharedUtilitySwift: NSObject {

    
    
    static func eval<V>(@SingleValueBuilder<V> _ value: () -> V) -> V {
        
        /// Src: https://forums.swift.org/t/how-to-assign-the-value-of-a-switch-statement-to-a-variable/50991/6
        
        value()
    }
    @resultBuilder
    enum SingleValueBuilder<V> {
        static func buildEither(first component: V) -> V {
            component
        }
        static func buildEither(second component: V) -> V {
            component
        }
        static func buildBlock(_ components: V) -> V {
            components
        }
    }
    
    @objc static func doOnMain(_ block: () -> ()) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync {
                block()
            }
        }
    }
    
    static func clip<T: Comparable>(_ value: T, betweenLow low: T, high: T) -> T { /// Might want to move this to Math.swift
        if value < low { return low }
        if value > high { return high }
        return value
    }
    
    @objc static func interpolateRects(_ t: Double, _ rect1: NSRect, _ rect2: NSRect) -> NSRect {
        let x = Math.scale(value: t, from: .unitInterval, to: Interval(rect1.origin.x, rect2.origin.x), allowOutOfBounds: true)
        let y = Math.scale(value: t, from: .unitInterval, to: Interval(rect1.origin.y, rect2.origin.y), allowOutOfBounds: true)
        let width = Math.scale(value: t, from: .unitInterval, to: Interval(rect1.width, rect2.width), allowOutOfBounds: true)
        let height = Math.scale(value: t, from: .unitInterval, to: Interval(rect1.height, rect2.height), allowOutOfBounds: true)
        
        return NSRect(x: x, y: y, width: width, height: height)
    }
    
    static func stringByAddingIndent(_ str: String, _ padding: String) -> String {
        /// Note: [Mar 2025] We have multiple implementations of an 'addIndent' function. We should probably merge them so we have one for objc and maybe another native Swift one for speed.
        let result = str.replacingOccurrences(
            of: "(\n|^)(.)",
            with: "$1" + padding + "$2",
            options: [.regularExpression],
            range: nil
        )
        return result;
    }
    
    static func dumpSwiftIvars(_ instance: Any) -> String {
        
        /// [Mar 2025] Creates a string describing all the 'children' of the instance using the Swift Mirror API.
        ///     I think this covers all the internal state held in native Swift properties.
        ///     Not sure it covers internal state held in objc ivars or associated objects.
        ///         (Send an `fp_ivarDescription` message to get objc ivar description.)
        ///
        ///     Mirror performance:
        ///         I think I heard multiple times that Mirror() is super slow and shouldn't be used. But I haven't tested that. Hopefully it's fast for debug logging.
        ///         Alternative: For Codable object's we could encode the to JSON to get a string-representation, but not sure that'd be faster.
    
        var result = ""
        
        result += "{\n"
        
        let padding = "    "
        
        for (i, (label, value)) in Mirror(reflecting: instance).children.enumerated() {
            if (i != 0) { result += "\n" }
            result += padding;
            result += label ?? "<nil>";
            let valueDesc: String
            if let value = value as? NSObject {
                valueDesc = value.debugDescription; /// Send `-[debugDescription]` message on objects since String(describing:) escapes newlines inside NSArray description (Observed in [Mar 2025])
            } else {
                valueDesc = String(describing: value);
            }
            if (!valueDesc.contains("\n")) {
                result += " = " + valueDesc;
            } else {
                result += " =\n" + stringByAddingIndent(valueDesc, padding);
            }
        }
        
        result += "\n}";
        
        return result;
    }
    
    static func insecureDeepCopy<T: NSCoding>(of original: T) throws -> T {
    
        /// Approach 4
        /// It seems theres a solution after all!!
        ///     See https://developer.apple.com/forums/thread/107533

        let data = try insecureArchive(of: original)
        let copy = try insecureUnarchive(data: data) as! T

        return copy
    }
    static func insecureArchive<T: NSCoding>(of object: T) throws -> Data {
        let result = try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: false)
        return result
    }
    static func insecureUnarchive(data: Data) throws -> NSCoding { /// TODO: Replace this with MFEncode() / MFDecode()
        
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = false
        let result = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as! NSCoding
        
        return result
    }
    
    @objc static func shallowCopy(ofObject object: NSObject) -> NSObject {
        
        /// Why aren't we using the normal NSKeyedArchiver methods for deep copying? I assume this is faster?
        /// Why is there no default "shallowCopy" method for objects?? Is this bad?
        /// Be careful not to mutate any properties in the copy because it's shallow (holds new references to the same old objects as the original)
        /// Reference on property attributes: https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ObjCRuntimeGuide/Articles/ocrtPropertyIntrospection.html
        
        /// Get reference to class of object
        let type = type(of: object)
        
        /// Create new instance of the same type
        let copy = type.init()
        
        /// Iterate properties
        ///     And copy the values over to the new instance
        
        var numberOfProperties: UInt32 = 0
        let propertyList = class_copyPropertyList(type, &numberOfProperties)
        
        guard let propertyList = propertyList else { fatalError() }
        
        for i in 0..<(Int(numberOfProperties)) {
            
            let property = propertyList[i]
            
            /// Get property name
            let propertyNameC = property_getName(property)
            let propertyName = String(cString: propertyNameC)
            
            /// Skip copying if readonly
            let readOnlyAttributeValue = property_copyAttributeValue(property, "R".cString(using: .utf8)!)
            let isReadOnly = readOnlyAttributeValue != nil
            if isReadOnly { continue }
            
            /// Get reference to original value
            let oldValue = object.value(forKey: propertyName)
            
            /// Skip copying if nil
            if oldValue == nil { continue }
        
            /// Assign oldValue to the copy
            copy.setValue(oldValue, forKey: propertyName)
        }
        
        free(propertyList)
        
        return copy;
    }
    
}
