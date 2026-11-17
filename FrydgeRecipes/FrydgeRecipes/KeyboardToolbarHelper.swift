//
//  KeyboardToolbarHelper.swift
//  FrydgeRecipes
//
//  Created by Josh on 19/10/2024.
//

import SwiftUI
import UIKit

struct KeyboardToolbarHelper: UIViewControllerRepresentable {

    func makeUIViewController(context: Context) -> UIViewController {
        return UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Adding a "Done" button to the keyboard
        let toolbar = UIToolbar()
        toolbar.sizeToFit()

        let flexSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let doneButton = UIBarButtonItem(title: "Done", style: .prominent, target: uiViewController.view, action: #selector(UIView.endEditing))
        doneButton.tintColor = .blue  // Ensure the button is blue

        toolbar.items = [flexSpace, doneButton]
        toolbar.barStyle = .default
        
        UITextField.appearance().inputAccessoryView = toolbar
        UITextView.appearance().inputAccessoryView = toolbar
    }
}
