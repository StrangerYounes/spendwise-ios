import AuthenticationServices
import SwiftUI
import UIKit
import SpendWiseCore

/// Asks Apple for a sign-in (or a fresh one, to revoke the token before deleting the account) and
/// waits for the answer. The nonce's hash goes in the request; Firebase gets the nonce itself.
@MainActor
final class AppleAuthorizer: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?
    /// Keeps itself alive until Apple answers (the controller holds its delegate weakly).
    private var retainedSelf: AppleAuthorizer?

    static func request(nonce: String, scopes: [ASAuthorization.Scope]) async throws -> ASAuthorizationAppleIDCredential {
        try await AppleAuthorizer().run(nonce: nonce, scopes: scopes)
    }

    private func run(nonce: String, scopes: [ASAuthorization.Scope]) async throws -> ASAuthorizationAppleIDCredential {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = scopes
        request.nonce = AppleNonce.sha256(nonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            retainedSelf = self
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<ASAuthorizationAppleIDCredential, Error>) {
        continuation?.resume(with: result)
        continuation = nil
        retainedSelf = nil
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        MainActor.assumeIsolated {
            if let credential { finish(.success(credential)) } else { finish(.failure(ASAuthorizationError(.invalidResponse))) }
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { UIApplication.topController?.view.window ?? ASPresentationAnchor() }
    }

    nonisolated static func isCancel(_ error: Error) -> Bool {
        (error as? ASAuthorizationError)?.code == .canceled
    }
}

/// Apple's standard "Sign in with Apple" button. The UIKit one (the same button SwiftUI's
/// SignInWithAppleButton wraps) because the tap first shows our "Your data in the cloud" notice;
/// SwiftUI's starts Apple's sheet at once.
struct AppleSignInButton: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let action: () -> Void

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(authorizationButtonType: .signIn, authorizationButtonStyle: colorScheme == .dark ? .white : .black)
        button.cornerRadius = 12
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        button.accessibilityIdentifier = "appleSignIn"
        return button
    }

    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}
