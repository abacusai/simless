// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Abacus.AI, Inc.

import SwiftUI

/// A Form in a NavigationStack with Cancel and Save, the way apps present an
/// editor as a sheet. Under the phone idiom on the Mac, SwiftUI handed the
/// sheet's NavigationStack the screen's iPad idiom and UIKit threw.
struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Ada Rivers"
    @State private var bio = ""
    @State private var publicProfile = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                    TextField("Bio", text: $bio)
                }
                Section {
                    Toggle("Public profile", isOn: $publicProfile)
                }
            }
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { dismiss() } }
            }
        }
    }
}

#Preview("Form") {
    EditProfileView()
}

#Preview("Sheet") {
    Text("Profile")
        .sheet(isPresented: .constant(true)) { EditProfileView() }
}
