//
//  listwidgetBundle.swift
//  listwidget
//

import WidgetKit
import SwiftUI

@main
struct listwidgetBundle: WidgetBundle {
    var body: some Widget {
        FrydgeListWidget()
        FrydgeQuickActionsWidget()
        FrydgeScanControl()
        FrydgeAddProductControl()
        FrydgeBasketControl()
    }
}
