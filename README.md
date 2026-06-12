# Reelevant SDK for iOS

Analytics tracking **and** real-time personalisation for iOS apps, powered by Reelevant.

## How to use

You need a `datasourceId` and a `companyId` to initialise the SDK:

```swift
let config = ReelevantAnalytics.Configuration(companyId: "<company id>", datasourceId: "<datasource id>")
let sdk = ReelevantAnalytics.SDK(configuration: config)
```

## Analytics

### Sending events

```swift
let event = ReelevantAnalytics.EventBuilder.page_view(labels: [:])
sdk.send(event: event)
```

### Current URL

When a user is browsing a page you should call the `sdk.setCurrentURL` method if you want to be able to filter on it in Reelevant.

### User identity

To identify a user, call `sdk.setUser(userId: "<user id>")` — the SDK stores the user ID on-device and sends it with every event and personalization call.

### Labels

Each event type allows you to pass additional info via `labels` (`Dictionary<String, String>`) on which you'll be able to filter in Reelevant.

```swift
let event = ReelevantAnalytics.EventBuilder.add_cart(ids: ["my-product-id"], labels: ["lang": "en_US"])
```

## Personalisation

The SDK can call the Reelevant runner to fetch personalised content for your app. Identity is automatically resolved from `setUser()` / device ID — no need to pass it manually.

> **Note:** The personalisation API requires iOS 13.0+ / macOS 10.15+ (uses Swift concurrency).

### Configuration

Personalization parameters are optional (defaults work out of the box):

```swift
let config = ReelevantAnalytics.Configuration(companyId: "...", datasourceId: "...")
// Optional overrides:
config.runnerUrl = "https://reelevant.run"         // default
config.personalizationTimeout = 5.0                 // default (seconds)
config.fallback = .empty                            // default

let sdk = ReelevantAnalytics.SDK(configuration: config)
```

### Single workflow run

```swift
let result = try await sdk.run(ReelevantAnalytics.RunOptions(
    workflowId: "wf-hero",
    entrypoint: "43a490a0"
))

switch result.body {
case .json(let data):
    renderCard(data)
case .html(let content):
    loadHtml(content)
case .image(let bytes):
    displayImage(bytes)
case .empty:
    showDefault()
}
```

### Multiple workflows in parallel

```swift
let results = await sdk.runAll([
    ReelevantAnalytics.RunOptions(workflowId: "wf-hero", entrypoint: "43a490a0"),
    ReelevantAnalytics.RunOptions(workflowId: "wf-sidebar", entrypoint: "b7e21f3c"),
])
```

### Click tracking

Every `RunResult` includes a `redirectionUrl` (for use as a link href) and a convenience `trackClick` method for fire-and-forget server-side tracking:

```swift
// Option 1: Use redirectionUrl as a link
openURL(URL(string: result.redirectionUrl)!)

// Option 2: Track the click programmatically
sdk.trackClick(result: result)
```

### RunResult fields

| Field | Type | Description |
|-------|------|-------------|
| `status` | `Int` | HTTP status code (0 for fallback) |
| `source` | `RunSource` | `.runner` or `.fallback` |
| `body` | `RunContent` | Typed content (`.json`, `.html`, `.image`, or `.empty`) |
| `metadata` | `[String: Any]` | Metadata from the output node |
| `properties` | `[String: Any]` | Output properties |
| `runId` | `String?` | Workflow run ID for tracking |
| `executionPath` | `[String]` | Branch IDs taken during execution |
| `redirectionUrl` | `String` | Pre-built click-through URL |

### Fallback strategies

```swift
config.fallback = .empty    // Default — returns an empty result on error
config.fallback = .error    // Throws the underlying error
config.fallback = .custom { options, error in
    // Return your own fallback result
    ReelevantAnalytics.RunResult(
        status: 0, source: .fallback, body: .empty,
        metadata: [:], properties: [:], runId: nil,
        executionPath: [], redirectionUrl: ""
    )
}
```

### Run options

| Option | Type | Description |
|--------|------|-------------|
| `workflowId` | `String` | Workflow ID |
| `entrypoint` | `String` | Entrypoint shortId |
| `userId` | `String?` | Override identity (default: auto-resolved) |
| `params` | `[String: String]?` | URL parameters forwarded to runner |
| `locale` | `String?` | Locale for content resolution |
| `timeout` | `TimeInterval?` | Per-call timeout override in seconds |

## Objective-C

The analytics portion is compatible with Objective-C apps:

```objective-c
#import "ViewController.h"
@import ReelevantAnalytics;

@interface ViewController ()
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
}

- (IBAction)myAction:(id)sender {
    Configuration *config = [[Configuration alloc] initWithCompanyId:@"foo" datasourceId:@"bar"];
    SDK *sdk = [[SDK alloc] initWithConfiguration:config];
    
    Event *event = [EventBuilder page_viewWithLabels:[[NSMutableDictionary alloc] init]];
    
    [sdk sendWithEvent:event];
}

@end
```

> **Note:** The personalisation API (`run` / `runAll`) is Swift-only (requires async/await).
