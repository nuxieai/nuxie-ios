# Purchase outbox

How the SDK sends App Store purchases to Nuxie and where a customer's access
comes from. iOS is the reference; the Android SDK follows the same contract.
The machine-readable contract is `fixtures/purchases/purchase-outbox.json`;
`PurchaseOwnershipClaimTests` drives it through the production entry points.

## The shape

1. **Access comes from the server profile.** The only exception is the
   buyer's own fresh purchase: a StoreKit transaction whose account token is
   the one Nuxie derives for the current customer, not revoked, and not yet
   answered by the server unlocks at once. After any answer to a purchase,
   accepted or refused, the SDK fetches that customer's profile again. A 200's
   `features` are kept in memory only until a profile requested after that
   answer lands. The SDK keeps no other copy of purchase access.
2. **The owner is what the server last said.** The SDK never works out who
   owns a purchase on the phone. A checkout binding only matches a StoreKit
   delivery to the checkout that started it, which names the customer the
   purchase is sent for.
3. **One durable outbox entry per purchase**, keyed by the StoreKit
   transaction id (Google Play: the purchase token).

### Early unlock on Android

Android has no client refund signal. Its early unlock is the buyer's own
unanswered outbox entry, sent until the server answers, so a refund or
cancellation before the server answers keeps the early unlock until that
answer: seconds online, or until the device is back online. That is the same
class of trade-off as the accepted offline case below. iOS keeps StoreKit's
signed revocation as a fact on the entry, so a refund StoreKit reports stops
the early unlock at once.

## The outbox entry

Recorded when the send is admitted, and sent unchanged by every retry:

| Field | Meaning |
| --- | --- |
| signed transaction | The StoreKit JWS (Play: purchase JSON and signature). A refund replaces it with the signed revocation, sent as a sync. |
| `reason` | `purchase` for the customer's own checkout (including a store delivery of a checkout still running, and the product the store says they already own, for that product only); `restore` for Restore; `sync` for everything else (store updates, launch recovery, deferred approvals, the scans after identify or reset). |
| requester distinct id | The customer the send is for: the one an explicit producer names (checkout, Restore, already owned), else the customer of the checkout binding the delivery matches, else the current customer. |
| `customer_kind` | `identified` if the requester signed in with `identify`, `anonymous` if not. When the SDK cannot tell (an entry admitted for a customer no longer on the device) it is `identified`: the server merges only owners declared anonymous, so such a customer can be moved but never merged away. |

Alongside it the entry keeps local bookkeeping that is not purchase
authority: whether the StoreKit transaction still has to be finished, and the
checkout's completion event while it has not been delivered.

Entries in a previous SDK's format are dropped when the outbox is read. They
are pre-GA local state, with no compatibility handling: StoreKit redelivers
unfinished transactions, which then go through the outbox normally.

### When an entry is answered

| Server answer | Entry | Profile refetched |
| --- | --- | --- |
| 200 | answered | yes |
| 409 (`app_store_purchase_conflict`) or 400 | answered | yes |
| 5xx, 401, 403, transport failure, a body the SDK cannot use | kept, one more attempt | no |

An answered entry is never sent again and its signed transaction is dropped.
It stays as the purchase's record, with its own flags for the StoreKit finish
and the checkout's completion delivery, until it expires with the 90-day
retention window. A later delivery of the same purchase (the store update
after the checkout, a launch scan) reads those flags: it does not send,
finish or deliver the completion again. Another customer's settled entry
(answered, finished, completion delivered) is only that record, so a
producer for a different customer starts the purchase's entry afresh.

### Admissions

Every write that changes what an entry sends (a new purchase, a Restore or
purchase claim, a refund's signed revocation, a stronger reason), or opens an
answered entry again, is an admission: the entry gets a fresh admission id.
Writes that only keep the books (the StoreKit finish, a delivered completion,
a failed attempt) keep the id. Each send carries the admission id of the entry
it sends. The server's answer marks the entry answered or counts a failed
attempt only while the entry still holds that id; otherwise the answer
is superseded and only triggers the profile refresh: it publishes no Features,
holds none and leaves the entry alone, even when that profile fetch fails.
So when a Restore rewrites an entry while the entry's earlier send is in
flight, that send's answer leaves the Restore claim waiting for its own.

Everything that changes one purchase runs one at a time. While an answer is
applied (its admission check, the entry change, the Feature publication and
the 200 hold, together), a new admission for that purchase (a Restore or
purchase claim, a commit's write, a refund) waits until it has finished, so a
Restore can never split the check from the publication. The profile refresh
the answer asks for runs after it.

Every answer passes one admission check before it may change its entry,
publish Features or hold a 200's Features: a scan's send, the outbox pass, a
Restore or purchase claim, and a purchase-backed Feature command alike. No
session cache decides sending, clearing or access; the entry's own state
does. A launch or identity scan with no purpose sends every unanswered entry
like any other pass.

An entry is answered only by the answer to a send of its own admission. No send, outbox pass or retry skips sending because the purchase
was accepted earlier in the session; the server answers a repeat send the
same way. A send that finds one of the same admission already in flight takes
that send's answer; one of another admission is waited out, then this one is
sent. The SDK remembers which accepted sends it reported as
`$purchase_synced`, by transaction, customer and admission, for telemetry
only. Commits of one purchase run one at a time, and each reads the entry
rather than an earlier commit's result. The outbox pass sends an entry only
while it still holds the admission the pass read; one answered or admitted
again meanwhile is left to its own send, never written back.

A purchase-backed Feature command carries the admission of the entry it uses.
Its accepted answer always returns the command's result and consumption
receipt to the caller, and the command applies its own post-use Feature
result, since the server has consumed the Feature. The admission check
decides only whether the answer is captured as purchase synced and answers
the entry; a superseded one only refreshes the profile.

### Retry rule

A kept entry records when it is due again: the time its send failed plus
`30 s × 2^(attempts − 1)`, capped at one hour. Entries survive restarts, and
so do their attempt count and due time.

The SDK keeps one timer for the whole outbox, set to the earliest time a
failed entry is due, or to now when one already is (its time passed while the
app was suspended). It is set again after every send result (accepted,
refused or failed) and at launch, so a purchase that fails for the first time
is retried after 30 s even while another entry waits out the hour; with no
failed entry waiting it is cancelled. When it fires, every entry whose time
has passed is sent; the others keep their own time. A due entry the timer's
pass tries but cannot send counts one more failed attempt, so its time moves
on. A timer pass sends only entries that are due: the scan of StoreKit's
unfinished transactions runs at launch, identify or reset, catalog change and
Restore, never from the timer. So does any send held back because a purchase-backed Feature command
holds the purchase: the timer sends the entry again if the command's answer
does not settle it.

Every entry still to be sent is also sent at every launch, at identify or
reset, and when a newly loaded profile changes the product catalog.

## Request

`POST /purchase`:

```json
{
  "type": "appstore",
  "transaction_jwt": "<signed transaction>",
  "distinct_id": "<requester distinct id>",
  "reason": "purchase | restore | sync",
  "customer_kind": "anonymous | identified"
}
```

Both `reason` and `customer_kind` are always sent.

## Restore

Restore sends every current StoreKit entitlement for the restoring customer
as `restore`. Each claim is written into the outbox as the restoring
customer's entry before it is sent, so a claim that gets no answer is retried
like any other entry, also after a relaunch. That includes a purchase the
server accepted earlier and a purchase another customer on this device has an
entry for: one entry per purchase, so the claim, the newer intent, takes that
entry over (a checkout completion that customer never delivered goes with
it). A Restore claim never unlocks before the server answers; Restore waits
for the answer. A Restore claim never reuses an earlier acceptance either,
this customer's or another's: it always admits its own claim and sends it,
and only its own answer counts. Writes to a purchase's entry are serialized with that
purchase's Feature command: a Restore (or purchase) claim of a purchase that a
purchase-backed Feature command holds waits for the command to finish, then
admits its claim and sends it. The result:

- `.restored` once the server accepted at least one;
- `.failed(restoreFailed(RestoreClaimError.ownedByAnotherAccount))` when it
  refused every claim;
- `.failed(restoreFailed(RestoreClaimError.unconfirmed))` when no claim got
  an answer;
- `.noPurchases` when there was nothing to send.

## What changes for an integrated app

- A purchase that moved to another customer (because they restored or bought
  it) stops granting on this device once the next profile arrives, which the
  SDK requests right after the server answers. Offline, a phone with a cached
  profile keeps showing a purchase that moved away until its next profile
  fetch, as it already does for a refund it has not seen yet.
- A purchase made outside Nuxie, or on this Apple Account by another
  customer, no longer unlocks before the server answers.
- `restorePurchases()` reports `.restored` only after the server grants at
  least one restored purchase.
- An answered purchase stays on the device as a small record, without its
  signed transaction, for the 90-day retention window, so a later delivery of
  it is not sent, finished or reported again.
- The Journey store-ownership check counts a StoreKit entitlement only when
  its account token is the current customer's.
