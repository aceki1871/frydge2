//
//  SignInHandler.swift
//  Recipes
//
//  Created by Josh on 07/10/2024.
//


import LocalAuthentication

class SignInHandler {
    static let shared = SignInHandler()

    // Function to handle biometric authentication
    func authenticateWithBiometrics(completion: @escaping (Bool, String?) -> Void) {
        let context = LAContext()
        var error: NSError?

        // Check if device supports biometric authentication
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            let reason = "Authenticate with Face ID or Touch ID to access Frydge."

            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, authenticationError in
                if success {
                    // Authentication successful
                    completion(true, nil)
                } else {
                    // Authentication failed
                    completion(false, authenticationError?.localizedDescription)
                }
            }
        } else {
            // Biometric authentication not available
            completion(false, "Face ID / Touch ID not available")
        }
    }
}