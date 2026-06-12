//
//  analytics.swift
//  analytics
//
//  Created by Valentin  on 06/09/2022.
//
import Foundation
import WebKit
#if canImport(UIKit)
import UIKit
#endif
import OSLog

@available(macOS 10.12, iOS 10.0, *)
@objc
public class ReelevantAnalytics: NSObject {
    
    /**
        Used to build `Event` which could be used in `send()` method
     */
    @objc
    @objcMembers
    public class EventBuilder: NSObject {
        public static func page_view(labels: Dictionary<String, String>) -> Event {
            return Event.init(name: "page_view", payload: convertLabelsToData(labels: labels))
        }
        
        public static func product_page(productId: String, labels: Dictionary<String, String>) -> Event {
            let payload = convertLabelsToData(labels: labels)
                .merging(["ids": DataValue.init(array: [productId])]) { (current, _) in current }
            return Event.init(name: "product_page", payload: payload)
        }
        
        public static func add_cart(ids: Array<String>, labels: Dictionary<String, String>) -> Event {
            let payload = convertLabelsToData(labels: labels)
                .merging(["ids": DataValue.init(array: ids)]) { (current, _) in current }
            return Event.init(name: "add_cart", payload: payload)
        }
        
        public static func purchase(ids: Array<String>, totalAmount: Float, labels: Dictionary<String, String>, transId: String?) -> Event {
            let payload = convertLabelsToData(labels: labels)
                .merging([
                    "ids": DataValue.init(array: ids),
                    "value": DataValue.init(number: totalAmount),
                    "transId": DataValue.init(string: transId)
                ]) { (current, _) in current }
            return Event.init(name: "purchase", payload: payload)
        }
        
        public static func category_view(categoryId: String, labels: Dictionary<String, String>) -> Event {
            let payload = convertLabelsToData(labels: labels)
                .merging(["ids": DataValue.init(array: [categoryId])]) { (current, _) in current }
            return Event.init(name: "category_view", payload: payload)
        }
        
        public static func brand_view(brandId: String, labels: Dictionary<String, String>) -> Event {
            let payload = convertLabelsToData(labels: labels)
                .merging(["ids": DataValue.init(array: [brandId])]) { (current, _) in current }
            return Event.init(name: "brand_view", payload: payload)
        }
        
        public static func product_hover(productId: String, labels: Dictionary<String, String>) -> Event {
            let payload = convertLabelsToData(labels: labels)
                .merging(["ids": DataValue.init(array: [productId])]) { (current, _) in current }
            return Event.init(name: "product_hover", payload: payload)
        }
        
        public static func custom(name: String, labels: Dictionary<String, String>) -> Event {
            return Event.init(name: name, payload: convertLabelsToData(labels: labels))
        }
    }
    
    /**
        Event built from the `EventBuilder`
     */
    @objc
    @objcMembers
    public class Event: NSObject {
        let name: String
        let payload: Dictionary<String, DataValue>
        
        public init (name: String, payload: Dictionary<String, DataValue>) {
            self.name = name
            self.payload = payload
        }
    }

    /**
        Configuration for the SDK
     */
    @objc
    @objcMembers
    public class Configuration: NSObject {
        public init (companyId: String, datasourceId: String) {
            self.companyId = companyId
            self.datasourceId = datasourceId
            self.endpoint = "https://collector.reelevant.com/collect/\(datasourceId)/rlvt"
            self.retry = 60 // 1m
            self.runnerUrl = "https://reelevant.run"
            self.personalizationTimeout = 5.0
            self.fallback = .empty
        }

        let companyId: String
        let datasourceId: String
        var currentUrl: String?
        var endpoint: String
        var retry: Double
        /// Runner endpoint URL for personalization (default: production runner).
        public var runnerUrl: String
        /// Global timeout in seconds for runner calls (default: 5s).
        public var personalizationTimeout: TimeInterval
        /// Fallback strategy when a runner call fails (Swift-only, not visible to ObjC).
        @nonobjc public var fallback: FallbackStrategy
    }

    /**
        Private configuration keys stored on the device
     */
    private static let UserIdConfigurationKey = "user-id"
    private static let TemporaryUserIdConfigurationKey = "tmp-id"
    private static let FailQueueConfigurationKey = "fail-queue"
    
    @objc
    public static func clearStorage () {
        UserDefaults.standard.removeObject(forKey: ReelevantAnalytics.UserIdConfigurationKey)
        UserDefaults.standard.removeObject(forKey: ReelevantAnalytics.TemporaryUserIdConfigurationKey)
        UserDefaults.standard.removeObject(forKey: ReelevantAnalytics.FailQueueConfigurationKey)
    }

    /**
        Custom class to be able to define array of string / string (optional) or number for `data` property
     */
    public class DataValue: NSObject, Codable {
        private var arrayValue: Array<String>? = nil
        private var stringValue: String? = nil
        private var floatValue: Float? = nil
        
        public required init (array: Array<String>) {
            self.arrayValue = array
        }
        public required init (string: String?) {
            self.stringValue = string
        }
        public required init (number: Float) {
            self.floatValue = number
        }
        
        public required init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            
            if let v = try? container.decode(Float.self) {
                self.floatValue = v
                return
            } else if let v = try? container.decode(Array<String>.self) {
                self.arrayValue = v
                return
            }
            
            let v = try? container.decode(String?.self)
            self.stringValue = v
        }
        
        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            
            if (self.arrayValue != nil) {
                try container.encode(self.arrayValue)
            } else if (self.floatValue != nil) {
                try container.encode(self.floatValue)
            } else if (self.stringValue != nil) {
                try container.encode(self.stringValue)
            } else {
                try container.encodeNil()
            }
        }
        
        public static func == (left: DataValue, right: DataValue) -> Bool {
            return
                left.stringValue == right.stringValue && // same string or nil
                left.floatValue == right.floatValue && // same number or nil
                (
                    (left.arrayValue == nil && right.arrayValue == nil) || // nil arrays
                    (left.arrayValue != nil && right.arrayValue != nil && left.arrayValue!.elementsEqual(right.arrayValue!)) // or same elements
                )
        }
    }

    /**
        Convert dict labels to data labels
     */
    static private func convertLabelsToData (labels: Dictionary<String, String>) -> Dictionary<String, DataValue> {
        return labels.mapValues { value in
            return DataValue.init(string: value)
        }
    }

    /**
        Sent event schema
        note: it could be a struct but we need Objective-C interoperability
     */
    public class BuiltEvent: NSObject, Codable {
        let key: String
        let name: String
        let url: String
        let tmpId: String
        let clientId: String?
        let data: Dictionary<String, DataValue>
        let eventId: String
        let v: Int
        let timestamp: Int64
        
        public init(
            key: String,
            name: String,
            url: String,
            tmpId: String,
            clientId: String?,
            data: Dictionary<String, DataValue>,
            eventId: String
        ) {
            self.key = key
            self.name = name
            self.url = url
            self.tmpId = tmpId
            self.clientId = clientId
            self.data = data
            self.eventId = eventId
            self.v = 1
            self.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        }
    }

    @objc
    @objcMembers
    public class SDK: NSObject {
        private var configuration: Configuration
        
        /**
            Create the SDK instance
         */
        public required init(configuration: Configuration) {
            self.configuration = configuration
            super.init()

            // Init tmp id
            let defaults = UserDefaults.standard
            if defaults.string(forKey: ReelevantAnalytics.TemporaryUserIdConfigurationKey) == nil {
                #if canImport(UIKit)
                let tmpId = UIDevice.current.identifierForVendor?.uuidString ?? self.randomIdentifier()
                #else
                let tmpId = self.randomIdentifier()
                #endif
                defaults.set(tmpId, forKey: ReelevantAnalytics.TemporaryUserIdConfigurationKey)
            }
            
            // Empty fail queue every 15s
            Timer.scheduledTimer(withTimeInterval: self.configuration.retry, repeats: true) { (timer) in
                var queue = self.getFailQueue()
                if queue.count > 0 {
                    // Remove element from queue
                    let data = queue.removeFirst()
                    let defaults = UserDefaults.standard
                    defaults.set(queue, forKey: ReelevantAnalytics.FailQueueConfigurationKey)

                    // We don't send the event if he is older than 15min
                    let decoder = JSONDecoder()
                    do {
                        let event = try decoder.decode(ReelevantAnalytics.BuiltEvent.self, from: data)
                        let timeSinceEvent = Int64(Date().timeIntervalSince1970 * 1000) - event.timestamp
                        if timeSinceEvent <= 15 * 60 * 1000 {
                            self.send(body: data)
                        }
                    } catch {
                         os_log("Unable to send queued event from Reelevant analytics SDK: %@", log: OSLog.default, type: .error, error as CVarArg)
                    }
                }
            }
        }
        
        /**
            Use this method to trigger an event with the associated payload and labels
            You should build event with the `EventBuilder` class:
            ```
            let event = EventBuilder.page_view(labels=[:])
            sdk.send(event)
            ```
         */
        public func send (event: Event) {
            self.publishEvent(name: event.name, payload: event.payload)
        }
        
        /**
            Set the current user (`clientId` property)
         */
        public func setUser (userId: String) {
            let defaults = UserDefaults.standard
            let currentValue = defaults.string(forKey: ReelevantAnalytics.UserIdConfigurationKey)
            if currentValue != userId {
                defaults.set(userId, forKey: ReelevantAnalytics.UserIdConfigurationKey)
                self.publishEvent(name: "identify", payload: [String: DataValue]())
            }
        }
        
        /**
            Set the current URL
         */
        public func setCurrentURL (url: String) {
            self.configuration.currentUrl = url
        }

        // MARK: - Personalization API

        /**
            Execute a single workflow run.
            Returns a typed RunResult with a discriminated body.
            userId is auto-resolved from stored identity (setUser / tmpId) unless overridden in options.
         */
        @available(iOS 13.0, macOS 10.15, *)
        public func run (_ options: RunOptions) async throws -> RunResult {
            let effectiveUserId = options.userId ?? self.resolveUserId()
            do {
                let result = try await executeRunnerCallAsync(
                    options: options,
                    runnerUrl: self.configuration.runnerUrl,
                    timeout: self.configuration.personalizationTimeout,
                    userId: effectiveUserId
                )
                return result
            } catch {
                return try self.handleRunError(options: options, error: error)
            }
        }

        /**
            Execute multiple workflow runs concurrently.
            Returns results in the same order as the input options.
         */
        @available(iOS 13.0, macOS 10.15, *)
        public func runAll (_ optionsList: [RunOptions]) async throws -> [RunResult] {
            try await withThrowingTaskGroup(of: (Int, RunResult).self) { group in
                for (index, options) in optionsList.enumerated() {
                    group.addTask {
                        let result = try await self.run(options)
                        return (index, result)
                    }
                }
                var results = [(Int, RunResult)]()
                for try await item in group {
                    results.append(item)
                }
                return results.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
        }

        /**
            Fire-and-forget click tracking. Calls the runner click endpoint without following redirects.
         */
        public func trackClick (result: RunResult) {
            result._trackClick()
        }

        private func resolveUserId () -> String {
            let defaults = UserDefaults.standard
            return defaults.string(forKey: ReelevantAnalytics.UserIdConfigurationKey)
                ?? defaults.string(forKey: ReelevantAnalytics.TemporaryUserIdConfigurationKey)
                ?? self.randomIdentifier()
        }

        private func handleRunError (options: RunOptions, error: Error) throws -> RunResult {
            switch self.configuration.fallback {
            case .error:
                throw error
            case .custom(let handler):
                return handler(options, error)
            case .empty:
                return RunResult(
                    status: 0, source: .fallback, body: .empty,
                    metadata: [:], properties: [:], runId: nil,
                    executionPath: [], redirectionUrl: ""
                )
            }
        }
        
        /**
            Generate random identifier (used for `tmpId` when unable to get IOS uuid, or for eventId)
         */
        private func randomIdentifier () -> String {
          let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
          return String((0..<25).map{ _ in letters.randomElement()! })
        }
        
        /**
            Retrieve fail queue from device
         */
        private func getFailQueue () -> Array<Data> {
            let defaults = UserDefaults.standard
            return (defaults.array(forKey: ReelevantAnalytics.FailQueueConfigurationKey) as? Array<Data>) ?? []
        }
        
        /**
            Add element to the current fail queue and save it on the local device
         */
        private func pushToFailQueue (data: Data) {
            let defaults = UserDefaults.standard
            var currentQueue = self.getFailQueue()
            currentQueue.append(data)
            defaults.set(currentQueue, forKey: ReelevantAnalytics.FailQueueConfigurationKey)
        }

        /**
            Build and send the event to the network
         */
        private func publishEvent (name: String, payload: Dictionary<String, DataValue>) {
            do {
                let builtEvent = self.buildEventPayload(name: name, payload: payload)
                let encoder = JSONEncoder()
                let data = try encoder.encode(builtEvent)
                return self.send(body: data)
            } catch {
                os_log("Unable to build event from Reelevant analytics SDK: %@", log: OSLog.default, type: .error, error as CVarArg)
            }
        }
        
        /**
            Send built event to the network
         */
        private func send (body: Data) {
            let url = URL(string: self.configuration.endpoint)!
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Avoid being considered as a bot
            request.setValue(WKWebView().value(forKey: "userAgent") as? String ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/104.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            request.httpMethod = "POST"
            request.httpBody = body

            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                let httpResponse = response as? HTTPURLResponse
                if error != nil || httpResponse?.statusCode ?? 500 >= 500 {
                    if error != nil {
                        os_log("Unable to send event from Reelevant analytics SDK: %@", log: OSLog.default, type: .error, error! as CVarArg)
                    } else {
                        os_log("Unable to send event from Reelevant analytics SDK: %@", log: OSLog.default, type: .error, "HTTP status code: \(httpResponse?.statusCode ?? 500)")
                    }
                    self.pushToFailQueue(data: body)
                }
            }

            task.resume()
        }
        
        /**
            Build the event payload
         */
        private func buildEventPayload (name: String, payload: Dictionary<String, DataValue>) -> BuiltEvent {
            let defaults = UserDefaults.standard
            let event = BuiltEvent(
                key: self.configuration.companyId,
                name: name,
                url: self.configuration.currentUrl ?? "unknown",
                tmpId: defaults.string(forKey: ReelevantAnalytics.TemporaryUserIdConfigurationKey)!,
                clientId: defaults.string(forKey: ReelevantAnalytics.UserIdConfigurationKey),
                data: payload,
                eventId: self.randomIdentifier()
            )
            return event
        }
    }
}
