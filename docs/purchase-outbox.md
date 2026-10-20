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

## The outbox entry

Recorded when the send is admitted, and sent unchanged by every retry:

| Field | Meaning |
| --- | --- |
| signed transaction | The StoreKit JWS (Play: purchase JSON and signature). A refund replaces it with the signed revocation, sent as a sync. |
| `reason` | `purchase` for the customer's own checkout (including a store delivery of a checkout still running, and the product the store says they already own, for that product only); `restore` for Restore; `sync` for everything else (store updates, launch recovery, deferred approvals, the scans after identify or reset). |
| requester distinct id | The customer the send is for: the one an explicit producer names (checkout, Restore, already owned), else the customer of the checkout binding the delivery matches, else the current customer. |
| `customer_kind` | `identified` if the requester signed in with `identify`, `anonymous` if not. When the SDK cannot tell (an entry with no recorded kind, for a customer no longer on the device) it is `identified`: the server merges only owners declared anonymous, so such a customer can be moved but never merged away. |

Alongside it the entry keeps local bookkeeping that is not purchase
authority: whether the StoreKit transaction still has to be finished, and the
checkout's completion event while it has not been delivered.

### When an entry clears

| Server answer | Entry | Profile refetched |
| --- | --- | --- |
| 200 | cleared | yes |
| 409 (`app_store_purchase_conflict`) or 400 | cleared | yes |
| 5xx, 401, 403, transport failure, a body the SDK cannot use | kept, one more attempt | no |

An entry whose StoreKit finish or completion delivery is still outstanding
stays answered (never sent again) until that bookkeeping is done.

### Retry rule

A kept entry is sent again after `30 s × 2^(attempts − 1)`, capped at one
hour, and also at every launch, at identify or reset, and when a newly
loaded profile changes the product catalog. Entries survive restarts; the
attempt count does too.

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
as `restore`, including one another customer on this device has an entry
for (that entry stays theirs and is sent as it was admitted). The result:

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
- The Journey store-ownership check counts a StoreKit entitlement only when
  its account token is the current customer's.
