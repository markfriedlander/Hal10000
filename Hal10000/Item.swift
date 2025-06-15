//
//  Item.swift
//  Hal10000
//
//  Created by Mark Friedlander on 6/14/25.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
