# Migrating to exact product placements

This pre-general-availability release intentionally replaces the draft product
purchase contract. It does not retain compatibility aliases or fallback
decoding for release descriptor V1.

## Store product type

`StoreProductType.nonRenewable` is now `StoreProductType.nonRenewing`. The new
name matches App Store Connect's non-renewing subscription terminology.

```swift
// Before
let type: StoreProductType = .nonRenewable

// After
let type: StoreProductType = .nonRenewing
```

## Purchase action

`PurchaseAction` no longer accepts a product ID and placement index. A purchase
now carries the stable `placementId` from the signed release descriptor. This
prevents the SDK from displaying one product and purchasing another when a
catalog or screen changes.

```swift
// Before
PurchaseAction(placementIndex: 0, productId: "premium_monthly")

// After
PurchaseAction(placementId: "premium_monthly_primary")
```

Apps do not normally construct this action directly. Republish Experiences so
the compiler emits release descriptor V2 before adopting this SDK version.
