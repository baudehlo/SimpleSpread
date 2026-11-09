# App Store trial and unlock

From 2.4.0, SimpleSpread on the App Store is a free download with a 14-day
trial and a one-time unlock. The open source build (GitHub Releases, or built
from this repository) has none of this: no trial, nothing to buy, never
restricted.

## How it behaves

| State | Editing and saving | What the user sees |
|---|---|---|
| Bought the app when it was paid | Yes | Nothing new |
| Bought the unlock | Yes | Nothing new |
| In the trial | Yes | "Free trial: N days left" in the status bar |
| Trial not started | No (reader mode) | The unlock window at every launch; a banner |
| Trial over | No (reader mode) | The unlock window once a day; a banner |

**Reader mode** opens, views, copies, finds, sorts, filters and freezes panes.
Everything else is refused: typing, paste, cut, delete, formatting, rows and
columns, sheets, charts, pivot tables, Save, Save As, Save a Copy, CSV import
and export, and File ▸ New. A refused edit opens the unlock window. Sorting
and filtering change only the view: a reader-mode document is never marked
as edited, so nothing autosaves or asks to be saved. The MCP server answers
only its read tools (`list_documents`, `read_range`, `screenshot`,
`select_range`, `close_document`, `list_charts`, `list_pivot_tables`).

When the trial runs out during a session, documents with unsaved changes
stay editable until they're closed, so the work can still be saved. A
purchase unlocks every open window at once.

One purchase covers Mac and iPad (Universal Purchase: one App Store record,
one bundle ID), and so does the trial: both are tied to the Apple Account.

## Code

- `Sources/SpreadsheetUI/Shared/AppLicense.swift`: the status, StoreKit 2
  (entitlements, purchase, restore, `Transaction.updates`), detecting
  paid-app customers, and putting documents in reader mode.
- `Shared/UnlockView.swift`: the unlock window, the reader-mode banner and
  the trial badge. Presented by `Mac/UnlockWindow.swift` and
  `iOS/UnlockSheet.swift`.
- `SpreadsheetDocument.isReadOnly` and `refuseIfReadOnly()`: every editing
  method checks it, so a path the UI forgets to disable is still refused.
  `DocumentCommand(reader: true)` marks the menu commands that stay enabled.
- `STORE_LICENSE` (Package.swift) compiles all of this into every iPad build
  and into `SIMPLESPREAD_APP_STORE=1` Mac builds only.

`SIMPLESPREAD_LICENSE=new|trial|expired` forces a state for screenshots and
testing. It can only restrict, never unlock. `SIMPLESPREAD_UNLOCK_WINDOW=1`
lets the unlock window appear under `SIMPLESPREAD_SCREENSHOT`.

## Paid-app customers

`AppTransaction.originalAppVersion` says which version someone first
downloaded. Anything before the first free version counts as bought:

- Mac: CFBundleShortVersionString below **2.4.0**.
- iPad: CFBundleVersion (the build number, the workflow's run number) below
  **5**.
- Either platform: an original download before `AppLicense.freeSince`
  (2026-12-01 UTC as committed). **Set it to the day the price goes to Free
  before building the release.** Too late only gives the unlock to a few
  early free downloads; too early is caught by the version check on the
  platform they bought.

In TestFlight and Xcode, `originalAppVersion` is always "1.0", so the check
is skipped there (`environment != .production`). It's unit-tested
(`ReaderModeTests`), but it can only really be tested in production. Be ready
to send unlock promo codes if a paying customer writes in.

## App Store Connect setup

1. **In-App Purchases ▸ +**, Non-Consumable:
   - Reference name "Unlock", Product ID `com.kikiplan.simplespread.unlock`,
     price **US$9.99**, all countries. Display name "Unlock SimpleSpread",
     description "Edit and save spreadsheets for good, on Mac and iPad."
   - Reference name "14-day Trial", Product ID
     `com.kikiplan.simplespread.trial`, price **Free**. Display name
     **"14-day Trial"** (guideline 3.1.1 asks for exactly this form),
     description "Use every feature free for 14 days."
   - Each needs a review screenshot: the unlock window (`SIMPLESPREAD_LICENSE=new
     SIMPLESPREAD_UNLOCK_WINDOW=1`).
   - Family Sharing: the paid app's setting carries over to nobody
     automatically; turn it on for the unlock if the app had it on.
2. Add both purchases to the 2.4.0 version (Mac and iPad: "In-App Purchases
   and Subscriptions" on the version page) so they're reviewed with it. The
   first IAPs must be submitted with a new app version.
3. Review notes, appended to the usual ones:

        SimpleSpread is now free to download with a 14-day free trial (a free non-consumable named "14-day Trial", per guideline 3.1.1) and a one-time unlock. The unlock window appears at first launch; it states the trial length, what stops working after it (editing and saving), and the unlock price. After the trial the app stays useful as a reader: documents open, and can be viewed, copied, sorted and filtered. Customers who bought the app when it was paid keep full access (AppTransaction originalAppVersion).

4. **Release order.** Release 2.4.0 manually. On release day, change the
   price to **Free** at the same moment (Pricing and Availability: a new
   price schedule starting today). A free download of 2.3.0 would be counted
   as a paid-app customer by the version check, so the price must not drop
   before 2.4.0 is out.
5. Update the listing (docs/APP-STORE-LISTING.md has the new text) and the
   mz-industries.com page wording ("free to try").

## Testing

- **iPad, Xcode:** the SimpleSpread scheme runs with
  `iOS/StoreKit/SimpleSpread.storekit`, so Start Free Trial and Unlock work
  locally. Debug ▸ StoreKit ▸ Manage Transactions deletes them to start over;
  Editor ▸ Time Rate speeds up the clock to watch the trial end.
- **Mac:** StoreKit needs the App Store build installed from TestFlight
  (sandbox account). `SIMPLESPREAD_APP_STORE=1 swift build` and
  `SIMPLESPREAD_LICENSE=…` show each state without purchases.
- **Paid-app path:** only in production; see above.
