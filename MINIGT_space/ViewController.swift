//
//  ViewController.swift
//  MINIGT_space
//
//  Created by Mclarenlife on 2026/5/22.
//

import UIKit
import SwiftUI

class ViewController: UIViewController {
    private var hostingController: UIHostingController<ContentView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        embedApp()
    }

    private func embedApp() {
        let host = UIHostingController(rootView: ContentView())
        hostingController = host

        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .systemBackground

        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        host.didMove(toParent: self)
    }
}
