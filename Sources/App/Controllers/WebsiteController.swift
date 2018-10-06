//
//  WebsiteController.swift
//  App
//
//  Created by Guilherme Rambo on 07/07/18.
//

import Foundation

import Foundation
import Vapor
import FluentPostgreSQL
import Leaf
import Authentication

final class WebsiteController: RouteCollection {

    let downloadsBaseURL: URL

    init(downloadsBaseURL: URL) {
        self.downloadsBaseURL = downloadsBaseURL
    }

    func boot(router: Router) throws {
        let authSessionRoutes = router.grouped(User.authSessionsMiddleware())
        
        authSessionRoutes.get(use: index)
        authSessionRoutes.get("download", String.parameter, use: download)
        authSessionRoutes.get("about", use: about)
        authSessionRoutes.get("search", use: search)
        
        let redirect = RedirectMiddleware<User>(path: "/users/login")

        let userRoutes = authSessionRoutes.grouped("users")
        
        userRoutes.get("login", use: loginForm)
        userRoutes.post(LoginRequest.self, at: "login", use: performLogin)
        userRoutes.get(String.parameter, use: userPage)
        
        let protectedUserRoutes = userRoutes.grouped(redirect)
        
        protectedUserRoutes.post("logout", use: logout)
        
        let protectedRoutes = authSessionRoutes.grouped(redirect)
     
        protectedRoutes.get("upload", use: upload)
    }

    func index(_ req: Request) throws -> Future<View> {
        let query = Shortcut.query(on: req).range(0...50).sort(\.createdAt, .descending).all()

        return query.flatMap(to: View.self) { shortcuts in
            let userFutures = shortcuts.map({ $0.user.query(on: req).first() })

            return userFutures.flatMap(to: View.self, on: req) { users in
                let unwrappedUsers = users.compactMap({ $0 })
                let cards = shortcuts.compactMap({ try? ShortcutCard($0, users: unwrappedUsers, req: req) })

                return try req.view().render("index", ["cards": cards])
            }
        }
    }

    private static let forceWorkflowExtension = false

    func download(_ req: Request) throws -> Future<Response> {
        let identifier = req.http.url.deletingPathExtension().lastPathComponent

        guard let id = UUID(uuidString: identifier) else {
            throw Abort(.badRequest)
        }

        let shortcutQuery = Shortcut.find(id, on: req)

        return shortcutQuery.flatMap(to: Response.self) { shortcut in
            guard let shortcut = shortcut else {
                throw Abort(.notFound)
            }

            let url = self.downloadsBaseURL.appendingPathComponent(shortcut.filePath)

            let download = B2Client.shared.fetchFileData(from: url, on: req)

            return download.map(to: Response.self) { data in
                guard let data = data else {
                    throw Abort(.notFound)
                }

                let ext = WebsiteController.forceWorkflowExtension ? "wflow" : "shortcut"

                let disposition = "attachment; filename=\"\(shortcut.title).\(ext)\""

                let status = HTTPResponseStatus(statusCode: 200)
                let headers = HTTPHeaders([
                    ("Content-Type","application/octet-stream"),
                    ("Content-Length", String(data.count)),
                    ("Content-Disposition", disposition)
                ])

                return req.response(http: HTTPResponse(status: status, headers: headers, body: data))
            }
        }
    }

    func upload(_ req: Request) throws -> Future<View> {
        let user = try req.requireAuthenticated(User.self)

        let context = UploadContext(user)
        
        return try req.view().render("upload", context)
    }

    func about(_ req: Request) throws -> Future<View> {
        return try req.view().render("about")
    }
    
    // MARK: - Search

    func search(_ req: Request) throws -> Future<View> {
        let searchTerm = req.query[String.self, at: "query"]
        
        guard let term = searchTerm else {
            return try req.view().render("search")
        }
        
        guard term.count > 3 else {
            return try req.view().render("search", ["error": true])
        }
        
        let query = Shortcut.query(on: req)
            .filter(\.title, PostgreSQLBinaryOperator.ilike, "%\(term)%")
            .range(0...100)
            .sort(\.createdAt, .descending)
            .all()
        
        return query.flatMap(to: View.self) { shortcuts in
            let userFutures = shortcuts.map({ $0.user.query(on: req).first() })
            
            return userFutures.flatMap(to: View.self, on: req) { users in
                let unwrappedUsers = users.compactMap({ $0 })
                let cards = shortcuts.compactMap({ try? ShortcutCard($0, users: unwrappedUsers, req: req) })
                
                return try req.view().render("search", ["cards": cards])
            }
        }
    }
    
    // MARK: - User routes
    
    func userPage(_ req: Request) throws -> Future<View> {
        let usernameParam = try req.parameters.next(String.self)
        
        let userQuery = User.query(on: req).filter(\.username, .equal, usernameParam).first()
        
        return userQuery.flatMap { user in
            guard let user = user else {
                throw Abort(.notFound)
            }
            
            let shortcuts = try user.shortcuts.query(on: req).all()
            
            return shortcuts.flatMap(to: View.self) { shortcuts in
                let cards = shortcuts.compactMap({ try? ShortcutCard($0, users: [user], req: req) })
                
                let context = UserDetailsContext(user: user, cards: cards)

                return try req.view().render("users/details", context)
            }
        }
    }
    
    func loginForm(_ req: Request) throws -> Future<View> {
        let hasError = req.query[Bool.self, at: "error"] != nil
        
        let context = LoginContext(error: hasError)
        
        return try req.view().render("users/login", context)
    }
    
    func performLogin(_ req: Request, login: LoginRequest) throws -> Future<Response> {
        let auth = User.authenticate(
            username: login.username,
            password: login.password,
            using: BCryptDigest(),
            on: req
        )
        
        return auth.map(to: Response.self) { user in
            guard let user = user else {
                return req.redirect(to: "/users/login?error=1")
            }
            
            try req.authenticateSession(user)
            
            return req.redirect(to: "/")
        }
    }
    
    func logout(_ req: Request) throws -> Response {
        try req.unauthenticateSession(User.self)
        
        return req.redirect(to: "/")
    }

}
