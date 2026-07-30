//! Exact-runtime-identity bounded, coarse screen-session protocol.
//!
//! The C layouts in this module are deliberately independent from the Rust
//! session model. Every caller-owned view is validated and copied before the
//! private adapter seam is entered, and every returned view borrows storage
//! owned by one opaque result handle. This keeps the public ABI stable while
//! `nuxie::flow_session` is completed behind the seam.

use super::*;
use std::{collections::HashSet, ffi::c_void, ptr, slice};

pub const NUX_SCREEN_MAX_ID_BYTE_LENGTH: u64 = 4_096;
pub const NUX_SCREEN_MAX_PATH_BYTE_LENGTH: u64 = 4_096;
pub const NUX_SCREEN_MAX_STRING_BYTE_LENGTH: u64 = 1_048_576;
pub const NUX_SCREEN_MAX_BATCH_ITEM_COUNT: u64 = 4_096;
pub const NUX_SCREEN_MAX_QUERY_COUNT: u64 = 4_096;
pub const NUX_SCREEN_MAX_OUTPUT_COUNT: u64 = 4_096;
pub const NUX_SCREEN_MAX_INSTANCE_COUNT: u64 = 4_096;
pub const NUX_SCREEN_MAX_LIST_ITEM_COUNT: u64 = 4_096;
pub const NUX_SCREEN_MAX_VALUE_EDGE_COUNT: u64 = 16_384;
pub const NUX_SCREEN_MAX_VALUE_DEPTH: u32 = 32;
pub const NUX_SCREEN_MAX_EVENT_PROPERTY_COUNT: u64 = 256;
pub const NUX_SCREEN_MAX_OPERATION_PAYLOAD_BYTE_LENGTH: u64 = 4_194_304;
pub const NUX_SCREEN_MAX_POINTER_COUNT: u64 = 32;

const NO_VALUE_ROOT: u32 = u32::MAX;
const NUX_SCREEN_MAX_HOST_COMMANDS_PER_CYCLE: usize = 256;

/// Stable-width selected-player kind.
pub type NuxScreenPlayerKind = u32;

pub const NUX_SCREEN_PLAYER_KIND_STATE_MACHINE: NuxScreenPlayerKind = 1;
pub const NUX_SCREEN_PLAYER_KIND_LINEAR_ANIMATION: NuxScreenPlayerKind = 2;
pub const NUX_SCREEN_PLAYER_KIND_STATIC: NuxScreenPlayerKind = 3;

/// Stable-width explicit player-selector kind. `DEFAULT` mirrors C++
/// `defaultScene`; the named variants mirror the two independent named lookup
/// operations on `ArtboardInstance`.
pub type NuxScreenPlayerSelectorKind = u32;

pub const NUX_SCREEN_PLAYER_SELECTOR_KIND_DEFAULT: NuxScreenPlayerSelectorKind = 0;
pub const NUX_SCREEN_PLAYER_SELECTOR_KIND_STATE_MACHINE: NuxScreenPlayerSelectorKind = 1;
pub const NUX_SCREEN_PLAYER_SELECTOR_KIND_LINEAR_ANIMATION: NuxScreenPlayerSelectorKind = 2;

/// Stable-width branch used by deterministic player selection.
pub type NuxScreenPlayerSelection = u32;

pub const NUX_SCREEN_PLAYER_SELECTION_EXPLICIT_STATE_MACHINE: NuxScreenPlayerSelection = 1;
pub const NUX_SCREEN_PLAYER_SELECTION_AUTHORED_DEFAULT_STATE_MACHINE: NuxScreenPlayerSelection = 2;
pub const NUX_SCREEN_PLAYER_SELECTION_FIRST_STATE_MACHINE: NuxScreenPlayerSelection = 3;
pub const NUX_SCREEN_PLAYER_SELECTION_FIRST_ANIMATION: NuxScreenPlayerSelection = 4;
pub const NUX_SCREEN_PLAYER_SELECTION_STATIC: NuxScreenPlayerSelection = 5;
pub const NUX_SCREEN_PLAYER_SELECTION_EXPLICIT_LINEAR_ANIMATION: NuxScreenPlayerSelection = 6;

/// Stable-width state-machine input kind returned by a player-input query.
pub type NuxScreenPlayerInputKind = u32;

pub const NUX_SCREEN_PLAYER_INPUT_KIND_BOOL: NuxScreenPlayerInputKind = 1;
pub const NUX_SCREEN_PLAYER_INPUT_KIND_NUMBER: NuxScreenPlayerInputKind = 2;
pub const NUX_SCREEN_PLAYER_INPUT_KIND_TRIGGER: NuxScreenPlayerInputKind = 3;

/// Stable-width generic session-operation kind.
pub type NuxScreenSessionOperationKind = u32;

pub const NUX_SCREEN_SESSION_OPERATION_KIND_STATE_BATCH: NuxScreenSessionOperationKind = 1;
pub const NUX_SCREEN_SESSION_OPERATION_KIND_POINTER_BATCH: NuxScreenSessionOperationKind = 2;
pub const NUX_SCREEN_SESSION_OPERATION_KIND_ADVANCE: NuxScreenSessionOperationKind = 3;
pub const NUX_SCREEN_SESSION_OPERATION_KIND_QUERY: NuxScreenSessionOperationKind = 4;
pub const NUX_SCREEN_SESSION_OPERATION_KIND_TEXT_RUN_BATCH: NuxScreenSessionOperationKind = 5;

/// Stable-width canonical-state mutation kind.
pub type NuxScreenStateMutationKind = u32;

pub const NUX_SCREEN_STATE_MUTATION_KIND_SET: NuxScreenStateMutationKind = 1;
pub const NUX_SCREEN_STATE_MUTATION_KIND_TRIGGER: NuxScreenStateMutationKind = 2;
pub const NUX_SCREEN_STATE_MUTATION_KIND_LIST_INSERT: NuxScreenStateMutationKind = 3;
pub const NUX_SCREEN_STATE_MUTATION_KIND_LIST_REMOVE: NuxScreenStateMutationKind = 4;
pub const NUX_SCREEN_STATE_MUTATION_KIND_LIST_SWAP: NuxScreenStateMutationKind = 5;
pub const NUX_SCREEN_STATE_MUTATION_KIND_LIST_MOVE: NuxScreenStateMutationKind = 6;
pub const NUX_SCREEN_STATE_MUTATION_KIND_LIST_SET: NuxScreenStateMutationKind = 7;
pub const NUX_SCREEN_STATE_MUTATION_KIND_LIST_CLEAR: NuxScreenStateMutationKind = 8;
pub const NUX_SCREEN_STATE_MUTATION_KIND_SET_INPUT_BOOL: NuxScreenStateMutationKind = 9;
pub const NUX_SCREEN_STATE_MUTATION_KIND_SET_INPUT_NUMBER: NuxScreenStateMutationKind = 10;
pub const NUX_SCREEN_STATE_MUTATION_KIND_FIRE_INPUT_TRIGGER: NuxScreenStateMutationKind = 11;
pub const NUX_SCREEN_STATE_MUTATION_KIND_SET_VIEW_MODEL: NuxScreenStateMutationKind = 12;

/// Stable-width instance reference used by state mutations.
pub type NuxScreenInstanceReferenceKind = u32;

pub const NUX_SCREEN_INSTANCE_REFERENCE_KIND_EXISTING: NuxScreenInstanceReferenceKind = 1;
pub const NUX_SCREEN_INSTANCE_REFERENCE_KIND_NEW: NuxScreenInstanceReferenceKind = 2;

/// Stable-width pointer command. Coordinates are already inverse-mapped into
/// artboard space and are never clamped by the runtime.
pub type NuxScreenPointerEventKind = u32;

pub const NUX_SCREEN_POINTER_EVENT_KIND_DOWN: NuxScreenPointerEventKind = 1;
pub const NUX_SCREEN_POINTER_EVENT_KIND_MOVE: NuxScreenPointerEventKind = 2;
pub const NUX_SCREEN_POINTER_EVENT_KIND_UP: NuxScreenPointerEventKind = 3;
pub const NUX_SCREEN_POINTER_EVENT_KIND_CANCEL: NuxScreenPointerEventKind = 4;
pub const NUX_SCREEN_POINTER_EVENT_KIND_EXIT: NuxScreenPointerEventKind = 5;

/// Stable-width query kind. Query results populate the result's borrowed
/// bootstrap, value, catalog, and player-input views; queries do not emit
/// ordered output records.
pub type NuxScreenQueryKind = u32;

pub const NUX_SCREEN_QUERY_KIND_BOOTSTRAP: NuxScreenQueryKind = 1;
pub const NUX_SCREEN_QUERY_KIND_VALUES: NuxScreenQueryKind = 2;
pub const NUX_SCREEN_QUERY_KIND_CATALOG: NuxScreenQueryKind = 3;
pub const NUX_SCREEN_QUERY_KIND_PLAYER_INPUTS: NuxScreenQueryKind = 4;

/// Stable-width recursive value kind.
pub type NuxScreenValueKind = u32;

pub const NUX_SCREEN_VALUE_KIND_NULL: NuxScreenValueKind = 0;
pub const NUX_SCREEN_VALUE_KIND_STRING: NuxScreenValueKind = 1;
pub const NUX_SCREEN_VALUE_KIND_NUMBER: NuxScreenValueKind = 2;
pub const NUX_SCREEN_VALUE_KIND_BOOL: NuxScreenValueKind = 3;
pub const NUX_SCREEN_VALUE_KIND_ENUM: NuxScreenValueKind = 4;
pub const NUX_SCREEN_VALUE_KIND_COLOR: NuxScreenValueKind = 5;
pub const NUX_SCREEN_VALUE_KIND_IMAGE: NuxScreenValueKind = 6;
pub const NUX_SCREEN_VALUE_KIND_OBJECT: NuxScreenValueKind = 7;
pub const NUX_SCREEN_VALUE_KIND_VIEW_MODEL: NuxScreenValueKind = 8;
pub const NUX_SCREEN_VALUE_KIND_LIST: NuxScreenValueKind = 9;
pub const NUX_SCREEN_VALUE_KIND_LIST_INDEX: NuxScreenValueKind = 10;

/// Stable-width observable output phase. Phases are monotonic inside one
/// cycle, and may restart when a pointer batch starts another immediate cycle.
pub type NuxScreenOutputPhase = u32;

/// Reserved for the runtime's ordering contract; current Rive event delays are
/// overshoot metadata and do not schedule callbacks into this phase.
pub const NUX_SCREEN_OUTPUT_PHASE_DELAYED_EVENT_CALLBACKS: NuxScreenOutputPhase = 0;
pub const NUX_SCREEN_OUTPUT_PHASE_REPORTED_EVENTS: NuxScreenOutputPhase = 1;
pub const NUX_SCREEN_OUTPUT_PHASE_RUNTIME_ADVANCE: NuxScreenOutputPhase = 2;
pub const NUX_SCREEN_OUTPUT_PHASE_VIEW_MODEL_CHANGES: NuxScreenOutputPhase = 3;
pub const NUX_SCREEN_OUTPUT_PHASE_HOST_WORK: NuxScreenOutputPhase = 4;
pub const NUX_SCREEN_OUTPUT_PHASE_RENDER: NuxScreenOutputPhase = 5;

/// Stable-width output payload family.
pub type NuxScreenOutputKind = u32;

pub const NUX_SCREEN_OUTPUT_KIND_REPORTED_EVENT: NuxScreenOutputKind = 2;
pub const NUX_SCREEN_OUTPUT_KIND_STATE_CHANGE: NuxScreenOutputKind = 3;
pub const NUX_SCREEN_OUTPUT_KIND_VIEW_MODEL_CHANGE: NuxScreenOutputKind = 4;
pub const NUX_SCREEN_OUTPUT_KIND_HOST_COMMAND: NuxScreenOutputKind = 5;
pub const NUX_SCREEN_OUTPUT_KIND_RENDER_REQUEST: NuxScreenOutputKind = 6;
pub const NUX_SCREEN_OUTPUT_KIND_RUNTIME_ADVANCED: NuxScreenOutputKind = 9;

/// Stable-width schema property kind. Values intentionally share the recursive
/// value-kind vocabulary where the property is directly representable.
pub type NuxScreenSchemaPropertyKind = u32;

pub const NUX_SCREEN_SCHEMA_PROPERTY_KIND_STRING: NuxScreenSchemaPropertyKind = 1;
pub const NUX_SCREEN_SCHEMA_PROPERTY_KIND_NUMBER: NuxScreenSchemaPropertyKind = 2;
pub const NUX_SCREEN_SCHEMA_PROPERTY_KIND_BOOL: NuxScreenSchemaPropertyKind = 3;
pub const NUX_SCREEN_SCHEMA_PROPERTY_KIND_TRIGGER: NuxScreenSchemaPropertyKind = 4;
pub const NUX_SCREEN_SCHEMA_PROPERTY_KIND_ENUM: NuxScreenSchemaPropertyKind = 5;
pub const NUX_SCREEN_SCHEMA_PROPERTY_KIND_COLOR: NuxScreenSchemaPropertyKind = 6;
pub const NUX_SCREEN_SCHEMA_PROPERTY_KIND_IMAGE: NuxScreenSchemaPropertyKind = 7;
pub const NUX_SCREEN_SCHEMA_PROPERTY_KIND_VIEW_MODEL: NuxScreenSchemaPropertyKind = 8;
pub const NUX_SCREEN_SCHEMA_PROPERTY_KIND_LIST: NuxScreenSchemaPropertyKind = 9;
pub const NUX_SCREEN_SCHEMA_PROPERTY_KIND_OBJECT: NuxScreenSchemaPropertyKind = 10;
pub const NUX_SCREEN_SCHEMA_PROPERTY_KIND_NULL: NuxScreenSchemaPropertyKind = 11;
pub const NUX_SCREEN_SCHEMA_PROPERTY_KIND_LIST_INDEX: NuxScreenSchemaPropertyKind = 12;

/// Configured-session descriptor for the bound runtime. `player_kind` selects
/// the default scene, a named state machine, or a named linear animation
/// without cross-kind fallback.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenConfiguredSessionDescriptor {
    pub struct_size: u32,
    pub player_kind: NuxScreenPlayerSelectorKind,
    pub artboard_name: NuxByteView,
    pub player_name: NuxByteView,
}

/// One node in a caller-owned recursive value arena. Array elements require
/// the exact published size. `identity_value` carries enum/image identity or
/// an authored component-list item index;
/// caller-supplied object/view-model nodes use `schema_id`, and view-model
/// nodes additionally use `instance_id`. Result view-model nodes always carry
/// stable `instance_id`; `schema_id` is populated when catalog metadata is in
/// the same result. Composite children occupy `first_edge..edge_count`.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenValueNode {
    pub struct_size: u32,
    pub kind: NuxScreenValueKind,
    pub number_value: f64,
    pub color_value: u32,
    /// Canonical false/true values are exactly 0 and 1.
    pub bool_value: u32,
    pub first_edge: u32,
    pub edge_count: u32,
    /// Canonical 0/1 presence flag for `instance_id`.
    pub has_instance_id: u32,
    pub instance_id: u64,
    pub identity_value: u64,
    pub string_value: NuxByteView,
    pub schema_id: NuxByteView,
}

/// One edge in a caller-owned recursive value arena. Object and view-model
/// edges require a nonempty UTF-8 key; list edges require an empty key.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenValueEdge {
    pub struct_size: u32,
    pub node_index: u32,
    pub key: NuxByteView,
}

/// One root binding from a stable external instance to a value-arena node.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenValueRootView {
    pub struct_size: u32,
    pub value_root_index: u32,
    pub instance_id: u64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenValueArena {
    pub struct_size: u32,
    pub nodes: *const NuxScreenValueNode,
    pub node_count: u64,
    pub edges: *const NuxScreenValueEdge,
    pub edge_count: u64,
}

/// One host-created view-model instance available to all mutations in the
/// same atomic batch. `local_id` is referenced by `NEW` instance references
/// and is resolved to a stable runtime ID only if the entire batch commits.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenNewInstance {
    pub struct_size: u32,
    pub local_id: u32,
    pub schema_name: NuxByteView,
    /// Null selects schema defaults; a name selects an authored template.
    pub authored_instance_name: NuxByteView,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenInstanceReference {
    pub kind: NuxScreenInstanceReferenceKind,
    pub local_id: u32,
    pub instance_id: u64,
}

/// One canonical-state mutation. `index` and `other_index` are interpreted by
/// list operations. A value root is required by scalar set and must be
/// `UINT32_MAX` for mutations without a scalar value. List insert/set select
/// their view-model item through `item` instead. Player-input operations use
/// `input_name` and require `instance`, `item`, and `path` to be zero/absent.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenStateMutation {
    pub struct_size: u32,
    pub kind: NuxScreenStateMutationKind,
    pub instance: NuxScreenInstanceReference,
    /// Used by list insert/set and view-model replacement; zeroed otherwise.
    pub item: NuxScreenInstanceReference,
    pub path: NuxByteView,
    pub input_name: NuxByteView,
    pub value_root_index: u32,
    pub index: u32,
    pub other_index: u32,
}

/// One all-or-nothing canonical-state batch. Rust prevalidates the complete
/// batch, including sequential list effects, before applying any mutation.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenStateBatch {
    pub struct_size: u32,
    /// Canonical 0/1 presence flag for `host_mutation_id`.
    pub has_host_mutation_id: u32,
    pub host_mutation_id: u64,
    pub value_arena: *const NuxScreenValueArena,
    pub new_instances: *const NuxScreenNewInstance,
    pub new_instance_count: u64,
    pub mutations: *const NuxScreenStateMutation,
    pub mutation_count: u64,
}

/// One semantic write to an exactly named `TextValueRun` on the root
/// artboard. Array elements require the exact published size.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenTextRunMutation {
    pub struct_size: u32,
    pub name: NuxByteView,
    pub text: NuxByteView,
}

/// One all-or-nothing root-artboard text-run batch.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenTextRunBatch {
    pub struct_size: u32,
    pub mutations: *const NuxScreenTextRunMutation,
    pub mutation_count: u64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenPointerEvent {
    pub struct_size: u32,
    pub kind: NuxScreenPointerEventKind,
    /// Positive session-scoped pointer identity, passed losslessly to runtime.
    pub pointer_id: i32,
    pub x: f32,
    pub y: f32,
    /// Event time in seconds from the platform's monotonic input clock.
    pub timestamp_seconds: f32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenPointerBatch {
    pub struct_size: u32,
    pub events: *const NuxScreenPointerEvent,
    pub event_count: u64,
}

/// One app-clock advance. The first delta after create/resume is zero. A live
/// Apple drawable and completion pair are borrowed only for the synchronous
/// perform call and follow the frame operation's exactly-once completion
/// contract.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenAdvanceOperation {
    pub struct_size: u32,
    pub timestamp_seconds: f64,
    pub delta_seconds: f32,
    /// Canonical false/true values are exactly 0 and 1.
    pub render: u32,
    pub apple_drawable: *mut c_void,
    pub completion_context: *mut c_void,
    pub completion_callback: Option<unsafe extern "C" fn(context: *mut c_void)>,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenQuery {
    pub struct_size: u32,
    pub kind: NuxScreenQueryKind,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenQueryBatch {
    pub struct_size: u32,
    pub queries: *const NuxScreenQuery,
    pub query_count: u64,
}

/// Tagged generic operation for the bound runtime. Exactly the pointer
/// selected by `kind` must be non-null and the other payload pointers null.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenSessionOperation {
    pub struct_size: u32,
    pub kind: NuxScreenSessionOperationKind,
    pub state_batch: *const NuxScreenStateBatch,
    pub pointer_batch: *const NuxScreenPointerBatch,
    pub advance: *const NuxScreenAdvanceOperation,
    pub query_batch: *const NuxScreenQueryBatch,
    pub text_run_batch: *const NuxScreenTextRunBatch,
}

/// Borrowed selected-player metadata owned by a session result.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenPlayerMetadataView {
    pub struct_size: u32,
    pub kind: NuxScreenPlayerKind,
    pub selection: NuxScreenPlayerSelection,
    /// Authored player index, or `UINT32_MAX` for a static artboard.
    pub player_index: u32,
    pub artboard_name: NuxByteView,
    pub player_name: NuxByteView,
    pub min_x: f32,
    pub min_y: f32,
    pub max_x: f32,
    pub max_y: f32,
}

/// Borrowed state-machine input snapshot. `name` is null only for an unnamed
/// authored input. The value root is owned by the same session result.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenPlayerInputView {
    pub struct_size: u32,
    pub kind: NuxScreenPlayerInputKind,
    pub value_root_index: u32,
    pub name: NuxByteView,
}

/// Borrowed view-model schema record owned by a session result.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenSchemaView {
    pub struct_size: u32,
    pub first_property: u32,
    pub property_count: u32,
    pub schema_id: NuxByteView,
    pub name: NuxByteView,
}

/// Borrowed schema-property record owned by a session result.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenSchemaPropertyView {
    pub struct_size: u32,
    pub kind: NuxScreenSchemaPropertyKind,
    pub schema_id: NuxByteView,
    pub property_id: NuxByteView,
    pub name: NuxByteView,
    /// Accepted nested schema, or an empty view for non-view-model properties.
    pub referenced_schema_id: NuxByteView,
    /// Stable span into the result's flattened enum-label table.
    pub first_enum_label: u32,
    pub enum_label_count: u32,
}

/// One authored enum label. `value` is its stable numeric enum identity.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenEnumLabelView {
    pub struct_size: u32,
    pub value: u32,
    pub label: NuxByteView,
}

/// Borrowed authored instance template. Templates are immutable creation
/// recipes and are not addressable live instances.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenInstanceTemplateView {
    pub struct_size: u32,
    pub authored_index: u32,
    pub schema_id: NuxByteView,
    pub authored_name: NuxByteView,
}

/// Borrowed stable external instance record owned by a session result.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenInstanceView {
    pub struct_size: u32,
    pub value_root_index: u32,
    pub is_root: u32,
    pub instance_id: u64,
    pub schema_id: NuxByteView,
    pub name: NuxByteView,
}

/// Mapping returned after an atomic batch commits host-created instances.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenCreatedInstanceView {
    pub struct_size: u32,
    pub local_id: u32,
    pub instance_id: u64,
}

/// Borrowed exact-order output owned by a session result. `payload_root_index`
/// is `UINT32_MAX` when the item has no typed arena payload. Host
/// commands always use an object node as their typed payload root and leave the
/// opaque `payload` byte view empty.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenOutputView {
    pub struct_size: u32,
    pub phase: NuxScreenOutputPhase,
    pub kind: NuxScreenOutputKind,
    pub payload_root_index: u32,
    /// Canonical 0/1 presence flag for `origin_mutation_id`.
    pub has_origin_mutation_id: u32,
    /// Canonical 0/1 presence flag for `instance_id`.
    pub has_instance_id: u32,
    pub sequence: u64,
    pub cycle: u64,
    pub origin_mutation_id: u64,
    pub instance_id: u64,
    pub event_type: u32,
    pub first_event_property: u32,
    pub event_property_count: u32,
    pub delay_seconds: f32,
    pub name: NuxByteView,
    pub path: NuxByteView,
    pub payload: NuxByteView,
    /// Canonical 0/1 presence flag for the paired OpenURL fields.
    pub has_open_url: u32,
    /// Exact authored URL for a reported OpenURL event. Empty-but-present URLs
    /// are distinguished from absent URLs by `has_open_url`.
    pub open_url: NuxByteView,
    /// Canonical OpenURL target paired with `open_url`.
    pub open_url_target: NuxByteView,
}

/// Borrowed typed property of a reported event.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenEventPropertyView {
    pub struct_size: u32,
    pub value_root_index: u32,
    /// Canonical 0/1 presence flag for `trigger_count`.
    pub has_trigger_count: u32,
    pub trigger_count: u64,
    /// Null when the authored event property has no name.
    pub name: NuxByteView,
}

/// Opaque owned session result. Every borrowed view returned by an accessor
/// remains valid until this handle is freed.
pub struct NuxScreenSessionResult {
    _private: [u8; 0],
}

#[derive(Debug, Clone, PartialEq)]
struct OwnedValueNode {
    kind: NuxScreenValueKind,
    number_value: f64,
    color_value: u32,
    bool_value: bool,
    first_edge: u32,
    edge_count: u32,
    instance_id: Option<u64>,
    identity_value: u64,
    string_value: Vec<u8>,
    schema_id: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct OwnedValueEdge {
    node_index: u32,
    key: Vec<u8>,
}

#[derive(Debug, Clone, Default, PartialEq)]
struct OwnedValueArena {
    nodes: Vec<OwnedValueNode>,
    edges: Vec<OwnedValueEdge>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct OwnedConfiguredSessionDescriptor {
    artboard_name: Option<String>,
    player: Option<OwnedPlayerSelector>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum OwnedPlayerSelector {
    StateMachine(String),
    LinearAnimation(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct OwnedNewInstance {
    local_id: u32,
    schema_name: Vec<u8>,
    authored_instance_name: Option<Vec<u8>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OwnedInstanceReference {
    Existing(u64),
    New(u32),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct OwnedStateMutation {
    kind: NuxScreenStateMutationKind,
    instance: Option<OwnedInstanceReference>,
    item: Option<OwnedInstanceReference>,
    path: Option<Vec<u8>>,
    input_name: Option<Vec<u8>>,
    value_root_index: Option<u32>,
    index: u32,
    other_index: u32,
}

#[derive(Debug, Clone, PartialEq)]
struct OwnedStateBatch {
    host_mutation_id: Option<u64>,
    value_arena: OwnedValueArena,
    new_instances: Vec<OwnedNewInstance>,
    mutations: Vec<OwnedStateMutation>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct OwnedTextRunMutation {
    name: Vec<u8>,
    text: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct OwnedPointerEvent {
    kind: NuxScreenPointerEventKind,
    pointer_id: i32,
    x: f32,
    y: f32,
    timestamp_seconds: f32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct OwnedQuery {
    kind: NuxScreenQueryKind,
}

#[derive(Debug)]
struct OwnedAdvanceOperation {
    timestamp_seconds: f64,
    delta_seconds: f32,
    render: bool,
    drawable_identity: usize,
    completion_context_identity: usize,
    completion_callback: Option<unsafe extern "C" fn(context: *mut c_void)>,
}

impl Drop for OwnedAdvanceOperation {
    fn drop(&mut self) {
        if let Some(callback) = self.completion_callback.take() {
            unsafe {
                callback(ptr::with_exposed_provenance_mut(
                    self.completion_context_identity,
                ));
            }
        }
    }
}

#[derive(Debug)]
enum OwnedSessionOperation {
    StateBatch(OwnedStateBatch),
    PointerBatch(Vec<OwnedPointerEvent>),
    Advance(OwnedAdvanceOperation),
    Query(Vec<OwnedQuery>),
    TextRunBatch(Vec<OwnedTextRunMutation>),
}

#[derive(Debug, Default)]
struct PayloadBudget {
    bytes: usize,
}

impl PayloadBudget {
    fn charge(&mut self, bytes: usize) -> Result<(), NuxStatus> {
        self.bytes = self
            .bytes
            .checked_add(bytes)
            .ok_or(NuxStatus::InvalidArgument)?;
        if self.bytes > NUX_SCREEN_MAX_OPERATION_PAYLOAD_BYTE_LENGTH as usize {
            return Err(NuxStatus::InvalidArgument);
        }
        Ok(())
    }
}

fn checked_count(count: u64, maximum: u64) -> Result<usize, NuxStatus> {
    if count > maximum {
        return Err(NuxStatus::InvalidArgument);
    }
    usize::try_from(count).map_err(|_| NuxStatus::InvalidArgument)
}

unsafe fn copy_array<T: Copy>(
    values: *const T,
    count: u64,
    maximum: u64,
) -> Result<Vec<T>, NuxStatus> {
    let count = checked_count(count, maximum)?;
    if count != 0 && values.is_null() {
        return Err(NuxStatus::NullArgument);
    }
    let byte_length = count
        .checked_mul(std::mem::size_of::<T>())
        .ok_or(NuxStatus::InvalidArgument)?;
    if byte_length > isize::MAX as usize {
        return Err(NuxStatus::InvalidArgument);
    }
    if count == 0 {
        return Ok(Vec::new());
    }
    // SAFETY: the FFI caller promises a readable array of the declared count
    // for this synchronous call. Every element and nested view is copied before
    // the private session seam can retain the request.
    Ok(unsafe { slice::from_raw_parts(values, count) }.to_vec())
}

fn copy_bytes(
    view: NuxByteView,
    maximum: u64,
    budget: &mut PayloadBudget,
) -> Result<Vec<u8>, NuxStatus> {
    let maximum = usize::try_from(maximum).map_err(|_| NuxStatus::InvalidArgument)?;
    let bytes = byte_vec(view, maximum)?;
    budget.charge(bytes.len())?;
    Ok(bytes)
}

fn copy_required_utf8(
    view: NuxByteView,
    maximum: u64,
    budget: &mut PayloadBudget,
) -> Result<Vec<u8>, NuxStatus> {
    let bytes = copy_bytes(view, maximum, budget)?;
    if bytes.is_empty() || std::str::from_utf8(&bytes).is_err() {
        return Err(NuxStatus::InvalidArgument);
    }
    Ok(bytes)
}

fn copy_optional_utf8(
    view: NuxByteView,
    maximum: u64,
    budget: &mut PayloadBudget,
) -> Result<Option<Vec<u8>>, NuxStatus> {
    if view.data.is_null() && view.len == 0 {
        return Ok(None);
    }
    copy_required_utf8(view, maximum, budget).map(Some)
}

unsafe fn copy_configured_session_descriptor(
    descriptor: *const NuxScreenConfiguredSessionDescriptor,
) -> Result<OwnedConfiguredSessionDescriptor, NuxStatus> {
    if descriptor.is_null() {
        return Err(NuxStatus::NullArgument);
    }
    let struct_size = unsafe { read_struct_size(descriptor) };
    if struct_size != size_u32::<NuxScreenConfiguredSessionDescriptor>() {
        return Err(NuxStatus::InvalidArgument);
    }
    let descriptor = unsafe { descriptor.read() };
    if !matches!(
        descriptor.player_kind,
        NUX_SCREEN_PLAYER_SELECTOR_KIND_DEFAULT
            | NUX_SCREEN_PLAYER_SELECTOR_KIND_STATE_MACHINE
            | NUX_SCREEN_PLAYER_SELECTOR_KIND_LINEAR_ANIMATION
    ) {
        return Err(NuxStatus::InvalidArgument);
    }
    let mut budget = PayloadBudget::default();
    let artboard_name = copy_optional_utf8(
        descriptor.artboard_name,
        NUX_SCREEN_MAX_ID_BYTE_LENGTH,
        &mut budget,
    )?
    .map(String::from_utf8)
    .transpose()
    .map_err(|_| NuxStatus::InvalidArgument)?;
    let player_name = copy_optional_utf8(
        descriptor.player_name,
        NUX_SCREEN_MAX_ID_BYTE_LENGTH,
        &mut budget,
    )?
    .map(String::from_utf8)
    .transpose()
    .map_err(|_| NuxStatus::InvalidArgument)?;
    let player = match (descriptor.player_kind, player_name) {
        (NUX_SCREEN_PLAYER_SELECTOR_KIND_DEFAULT, None) => None,
        (NUX_SCREEN_PLAYER_SELECTOR_KIND_STATE_MACHINE, Some(name)) if !name.is_empty() => {
            Some(OwnedPlayerSelector::StateMachine(name))
        }
        (NUX_SCREEN_PLAYER_SELECTOR_KIND_LINEAR_ANIMATION, Some(name)) if !name.is_empty() => {
            Some(OwnedPlayerSelector::LinearAnimation(name))
        }
        _ => return Err(NuxStatus::InvalidArgument),
    };
    Ok(OwnedConfiguredSessionDescriptor {
        artboard_name,
        player,
    })
}

unsafe fn copy_value_arena(
    arena: *const NuxScreenValueArena,
    budget: &mut PayloadBudget,
) -> Result<OwnedValueArena, NuxStatus> {
    if arena.is_null() {
        return Ok(OwnedValueArena::default());
    }
    if unsafe { read_struct_size(arena) } != size_u32::<NuxScreenValueArena>() {
        return Err(NuxStatus::InvalidArgument);
    }
    let arena = unsafe { arena.read() };
    let raw_nodes = unsafe {
        copy_array(
            arena.nodes,
            arena.node_count,
            NUX_SCREEN_MAX_BATCH_ITEM_COUNT,
        )?
    };
    let raw_edges = unsafe {
        copy_array(
            arena.edges,
            arena.edge_count,
            NUX_SCREEN_MAX_VALUE_EDGE_COUNT,
        )?
    };
    let mut nodes = Vec::with_capacity(raw_nodes.len());
    for node in raw_nodes {
        if node.struct_size != size_u32::<NuxScreenValueNode>() {
            return Err(NuxStatus::InvalidArgument);
        }
        let string_value =
            copy_bytes(node.string_value, NUX_SCREEN_MAX_STRING_BYTE_LENGTH, budget)?;
        let schema_id = copy_bytes(node.schema_id, NUX_SCREEN_MAX_ID_BYTE_LENGTH, budget)?;
        let instance_id = match node.has_instance_id {
            0 if node.instance_id == 0 => None,
            1 if node.instance_id != 0 => Some(node.instance_id),
            _ => return Err(NuxStatus::InvalidArgument),
        };
        if (!string_value.is_empty() && std::str::from_utf8(&string_value).is_err())
            || (!schema_id.is_empty() && std::str::from_utf8(&schema_id).is_err())
        {
            return Err(NuxStatus::InvalidArgument);
        }
        if node.bool_value > 1 {
            return Err(NuxStatus::InvalidArgument);
        }
        let first_edge =
            usize::try_from(node.first_edge).map_err(|_| NuxStatus::InvalidArgument)?;
        let edge_count =
            usize::try_from(node.edge_count).map_err(|_| NuxStatus::InvalidArgument)?;
        let edge_end = first_edge
            .checked_add(edge_count)
            .ok_or(NuxStatus::InvalidArgument)?;
        if edge_count > NUX_SCREEN_MAX_LIST_ITEM_COUNT as usize || edge_end > raw_edges.len() {
            return Err(NuxStatus::InvalidArgument);
        }
        let has_edges = edge_count != 0;
        let has_canonical_edge_start = has_edges || node.first_edge == 0;
        let number_is_zero = node.number_value.to_bits() == 0;
        let fields_are_canonical = match node.kind {
            NUX_SCREEN_VALUE_KIND_NULL => {
                number_is_zero
                    && node.color_value == 0
                    && node.bool_value == 0
                    && node.identity_value == 0
                    && string_value.is_empty()
                    && instance_id.is_none()
                    && schema_id.is_empty()
                    && !has_edges
                    && has_canonical_edge_start
            }
            NUX_SCREEN_VALUE_KIND_STRING => {
                number_is_zero
                    && node.color_value == 0
                    && node.bool_value == 0
                    && node.identity_value == 0
                    && instance_id.is_none()
                    && schema_id.is_empty()
                    && !has_edges
                    && has_canonical_edge_start
            }
            NUX_SCREEN_VALUE_KIND_NUMBER => {
                node.number_value.is_finite()
                    && node.number_value.abs() <= f64::from(f32::MAX)
                    && node.color_value == 0
                    && node.bool_value == 0
                    && node.identity_value == 0
                    && string_value.is_empty()
                    && instance_id.is_none()
                    && schema_id.is_empty()
                    && !has_edges
                    && has_canonical_edge_start
            }
            NUX_SCREEN_VALUE_KIND_BOOL => {
                number_is_zero
                    && node.color_value == 0
                    && node.identity_value == 0
                    && string_value.is_empty()
                    && instance_id.is_none()
                    && schema_id.is_empty()
                    && !has_edges
                    && has_canonical_edge_start
            }
            NUX_SCREEN_VALUE_KIND_COLOR => {
                number_is_zero
                    && node.bool_value == 0
                    && node.identity_value == 0
                    && string_value.is_empty()
                    && instance_id.is_none()
                    && schema_id.is_empty()
                    && !has_edges
                    && has_canonical_edge_start
            }
            NUX_SCREEN_VALUE_KIND_ENUM
            | NUX_SCREEN_VALUE_KIND_IMAGE
            | NUX_SCREEN_VALUE_KIND_LIST_INDEX => {
                number_is_zero
                    && node.color_value == 0
                    && node.bool_value == 0
                    && string_value.is_empty()
                    && instance_id.is_none()
                    && schema_id.is_empty()
                    && !has_edges
                    && has_canonical_edge_start
            }
            NUX_SCREEN_VALUE_KIND_OBJECT => {
                number_is_zero
                    && node.color_value == 0
                    && node.bool_value == 0
                    && node.identity_value == 0
                    && string_value.is_empty()
                    && instance_id.is_none()
                    && !schema_id.is_empty()
                    && has_canonical_edge_start
            }
            NUX_SCREEN_VALUE_KIND_VIEW_MODEL => {
                number_is_zero
                    && node.color_value == 0
                    && node.bool_value == 0
                    && node.identity_value == 0
                    && string_value.is_empty()
                    && instance_id.is_some()
                    && !schema_id.is_empty()
                    && has_canonical_edge_start
            }
            NUX_SCREEN_VALUE_KIND_LIST => {
                number_is_zero
                    && node.color_value == 0
                    && node.bool_value == 0
                    && node.identity_value == 0
                    && string_value.is_empty()
                    && instance_id.is_none()
                    && schema_id.is_empty()
                    && has_canonical_edge_start
            }
            _ => false,
        };
        if !fields_are_canonical {
            return Err(NuxStatus::InvalidArgument);
        }
        nodes.push(OwnedValueNode {
            kind: node.kind,
            number_value: node.number_value,
            color_value: node.color_value,
            bool_value: node.bool_value == 1,
            first_edge: node.first_edge,
            edge_count: node.edge_count,
            instance_id,
            identity_value: node.identity_value,
            string_value,
            schema_id,
        });
    }
    let mut edges = Vec::with_capacity(raw_edges.len());
    for edge in raw_edges {
        if edge.struct_size != size_u32::<NuxScreenValueEdge>() {
            return Err(NuxStatus::InvalidArgument);
        }
        let node_index =
            usize::try_from(edge.node_index).map_err(|_| NuxStatus::InvalidArgument)?;
        if node_index >= nodes.len() {
            return Err(NuxStatus::InvalidArgument);
        }
        let key = copy_bytes(edge.key, NUX_SCREEN_MAX_PATH_BYTE_LENGTH, budget)?;
        if !key.is_empty() && std::str::from_utf8(&key).is_err() {
            return Err(NuxStatus::InvalidArgument);
        }
        edges.push(OwnedValueEdge {
            node_index: edge.node_index,
            key,
        });
    }
    validate_value_graph(&nodes, &edges)?;
    Ok(OwnedValueArena { nodes, edges })
}

fn validate_value_graph(
    nodes: &[OwnedValueNode],
    edges: &[OwnedValueEdge],
) -> Result<(), NuxStatus> {
    for node in nodes {
        let start = node.first_edge as usize;
        let end = start
            .checked_add(node.edge_count as usize)
            .ok_or(NuxStatus::InvalidArgument)?;
        let node_edges = edges.get(start..end).ok_or(NuxStatus::InvalidArgument)?;
        match node.kind {
            NUX_SCREEN_VALUE_KIND_OBJECT | NUX_SCREEN_VALUE_KIND_VIEW_MODEL => {
                let mut keys = HashSet::with_capacity(node_edges.len());
                for edge in node_edges {
                    if edge.key.is_empty() || !keys.insert(edge.key.as_slice()) {
                        return Err(NuxStatus::InvalidArgument);
                    }
                }
            }
            NUX_SCREEN_VALUE_KIND_LIST => {
                if node_edges.iter().any(|edge| !edge.key.is_empty()) {
                    return Err(NuxStatus::InvalidArgument);
                }
            }
            _ if !node_edges.is_empty() => return Err(NuxStatus::InvalidArgument),
            _ => {}
        }
    }
    let mut states = vec![0_u8; nodes.len()];
    let mut heights = vec![0_u32; nodes.len()];
    for node_index in 0..nodes.len() {
        validate_value_height(node_index, 0, nodes, edges, &mut states, &mut heights)?;
    }
    Ok(())
}

fn validate_value_height(
    node_index: usize,
    depth: u32,
    nodes: &[OwnedValueNode],
    edges: &[OwnedValueEdge],
    states: &mut [u8],
    heights: &mut [u32],
) -> Result<u32, NuxStatus> {
    if depth > NUX_SCREEN_MAX_VALUE_DEPTH {
        return Err(NuxStatus::InvalidArgument);
    }
    match states
        .get(node_index)
        .copied()
        .ok_or(NuxStatus::InvalidArgument)?
    {
        1 => return Err(NuxStatus::InvalidArgument),
        2 => {
            return heights
                .get(node_index)
                .copied()
                .ok_or(NuxStatus::InvalidArgument);
        }
        _ => {}
    }
    *states
        .get_mut(node_index)
        .ok_or(NuxStatus::InvalidArgument)? = 1;
    let node = nodes.get(node_index).ok_or(NuxStatus::InvalidArgument)?;
    let start = node.first_edge as usize;
    let end = start
        .checked_add(node.edge_count as usize)
        .ok_or(NuxStatus::InvalidArgument)?;
    let mut height = 0_u32;
    for edge in edges.get(start..end).ok_or(NuxStatus::InvalidArgument)? {
        let child_height = validate_value_height(
            edge.node_index as usize,
            depth.checked_add(1).ok_or(NuxStatus::InvalidArgument)?,
            nodes,
            edges,
            states,
            heights,
        )?;
        height = height.max(
            child_height
                .checked_add(1)
                .ok_or(NuxStatus::InvalidArgument)?,
        );
        if height > NUX_SCREEN_MAX_VALUE_DEPTH {
            return Err(NuxStatus::InvalidArgument);
        }
    }
    *states
        .get_mut(node_index)
        .ok_or(NuxStatus::InvalidArgument)? = 2;
    *heights
        .get_mut(node_index)
        .ok_or(NuxStatus::InvalidArgument)? = height;
    Ok(height)
}

unsafe fn copy_state_batch(
    batch: *const NuxScreenStateBatch,
) -> Result<OwnedStateBatch, NuxStatus> {
    if batch.is_null() {
        return Err(NuxStatus::NullArgument);
    }
    if unsafe { read_struct_size(batch) } != size_u32::<NuxScreenStateBatch>() {
        return Err(NuxStatus::InvalidArgument);
    }
    let batch = unsafe { batch.read() };
    let mut budget = PayloadBudget::default();
    let host_mutation_id = match batch.has_host_mutation_id {
        0 if batch.host_mutation_id == 0 => None,
        1 => Some(batch.host_mutation_id),
        _ => return Err(NuxStatus::InvalidArgument),
    };
    let value_arena = unsafe { copy_value_arena(batch.value_arena, &mut budget)? };
    let raw_instances = unsafe {
        copy_array(
            batch.new_instances,
            batch.new_instance_count,
            NUX_SCREEN_MAX_INSTANCE_COUNT,
        )?
    };
    let raw_mutations = unsafe {
        copy_array(
            batch.mutations,
            batch.mutation_count,
            NUX_SCREEN_MAX_BATCH_ITEM_COUNT,
        )?
    };
    if raw_instances
        .len()
        .checked_add(raw_mutations.len())
        .is_none_or(|item_count| item_count > NUX_SCREEN_MAX_BATCH_ITEM_COUNT as usize)
    {
        return Err(NuxStatus::InvalidArgument);
    }
    if raw_instances.is_empty() && raw_mutations.is_empty() {
        return Err(NuxStatus::InvalidArgument);
    }
    let mut new_instances = Vec::with_capacity(raw_instances.len());
    let mut local_ids = HashSet::with_capacity(raw_instances.len());
    for instance in raw_instances {
        if instance.struct_size != size_u32::<NuxScreenNewInstance>() {
            return Err(NuxStatus::InvalidArgument);
        }
        if !local_ids.insert(instance.local_id) {
            return Err(NuxStatus::InvalidArgument);
        }
        let schema_name = copy_required_utf8(
            instance.schema_name,
            NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            &mut budget,
        )?;
        let authored_instance_name = copy_optional_utf8(
            instance.authored_instance_name,
            NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            &mut budget,
        )?;
        new_instances.push(OwnedNewInstance {
            local_id: instance.local_id,
            schema_name,
            authored_instance_name,
        });
    }
    let mut mutations = Vec::with_capacity(raw_mutations.len());
    for mutation in raw_mutations {
        if mutation.struct_size != size_u32::<NuxScreenStateMutation>() {
            return Err(NuxStatus::InvalidArgument);
        }
        let path = copy_optional_utf8(mutation.path, NUX_SCREEN_MAX_PATH_BYTE_LENGTH, &mut budget)?;
        let input_name = copy_optional_utf8(
            mutation.input_name,
            NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            &mut budget,
        )?;
        let value_root_index = optional_value_root(mutation.value_root_index, &value_arena)?;
        let (instance, item, valid_shape) = match mutation.kind {
            NUX_SCREEN_STATE_MUTATION_KIND_SET => (
                Some(copy_instance_reference(mutation.instance)?),
                None,
                value_root_index.is_some()
                    && path.is_some()
                    && input_name.is_none()
                    && instance_reference_is_zero(mutation.item)
                    && mutation.index == 0
                    && mutation.other_index == 0,
            ),
            NUX_SCREEN_STATE_MUTATION_KIND_TRIGGER => (
                Some(copy_instance_reference(mutation.instance)?),
                None,
                value_root_index.is_none()
                    && path.is_some()
                    && input_name.is_none()
                    && instance_reference_is_zero(mutation.item)
                    && mutation.index == 0
                    && mutation.other_index == 0,
            ),
            NUX_SCREEN_STATE_MUTATION_KIND_SET_VIEW_MODEL => (
                Some(copy_instance_reference(mutation.instance)?),
                Some(copy_instance_reference(mutation.item)?),
                value_root_index.is_none()
                    && path.is_some()
                    && input_name.is_none()
                    && mutation.index == 0
                    && mutation.other_index == 0,
            ),
            NUX_SCREEN_STATE_MUTATION_KIND_LIST_INSERT
            | NUX_SCREEN_STATE_MUTATION_KIND_LIST_SET => (
                Some(copy_instance_reference(mutation.instance)?),
                Some(copy_instance_reference(mutation.item)?),
                value_root_index.is_none()
                    && path.is_some()
                    && input_name.is_none()
                    && mutation.other_index == 0,
            ),
            NUX_SCREEN_STATE_MUTATION_KIND_LIST_REMOVE => (
                Some(copy_instance_reference(mutation.instance)?),
                None,
                value_root_index.is_none()
                    && path.is_some()
                    && input_name.is_none()
                    && instance_reference_is_zero(mutation.item)
                    && mutation.other_index == 0,
            ),
            NUX_SCREEN_STATE_MUTATION_KIND_LIST_SWAP | NUX_SCREEN_STATE_MUTATION_KIND_LIST_MOVE => {
                (
                    Some(copy_instance_reference(mutation.instance)?),
                    None,
                    value_root_index.is_none()
                        && path.is_some()
                        && input_name.is_none()
                        && instance_reference_is_zero(mutation.item),
                )
            }
            NUX_SCREEN_STATE_MUTATION_KIND_LIST_CLEAR => (
                Some(copy_instance_reference(mutation.instance)?),
                None,
                value_root_index.is_none()
                    && path.is_some()
                    && input_name.is_none()
                    && instance_reference_is_zero(mutation.item)
                    && mutation.index == 0
                    && mutation.other_index == 0,
            ),
            NUX_SCREEN_STATE_MUTATION_KIND_SET_INPUT_BOOL => (
                None,
                None,
                value_root_has_kind(value_root_index, &value_arena, NUX_SCREEN_VALUE_KIND_BOOL)
                    && input_name.is_some()
                    && path.is_none()
                    && instance_reference_is_zero(mutation.instance)
                    && instance_reference_is_zero(mutation.item)
                    && mutation.index == 0
                    && mutation.other_index == 0,
            ),
            NUX_SCREEN_STATE_MUTATION_KIND_SET_INPUT_NUMBER => (
                None,
                None,
                value_root_has_kind(value_root_index, &value_arena, NUX_SCREEN_VALUE_KIND_NUMBER)
                    && input_name.is_some()
                    && path.is_none()
                    && instance_reference_is_zero(mutation.instance)
                    && instance_reference_is_zero(mutation.item)
                    && mutation.index == 0
                    && mutation.other_index == 0,
            ),
            NUX_SCREEN_STATE_MUTATION_KIND_FIRE_INPUT_TRIGGER => (
                None,
                None,
                value_root_index.is_none()
                    && input_name.is_some()
                    && path.is_none()
                    && instance_reference_is_zero(mutation.instance)
                    && instance_reference_is_zero(mutation.item)
                    && mutation.index == 0
                    && mutation.other_index == 0,
            ),
            _ => (None, None, false),
        };
        if !valid_shape {
            return Err(NuxStatus::InvalidArgument);
        }
        if matches!(instance, Some(OwnedInstanceReference::New(local_id)) if !local_ids.contains(&local_id))
        {
            return Err(NuxStatus::InvalidArgument);
        }
        if matches!(item, Some(OwnedInstanceReference::New(local_id)) if !local_ids.contains(&local_id))
        {
            return Err(NuxStatus::InvalidArgument);
        }
        mutations.push(OwnedStateMutation {
            kind: mutation.kind,
            instance,
            item,
            path,
            input_name,
            value_root_index,
            index: mutation.index,
            other_index: mutation.other_index,
        });
    }
    Ok(OwnedStateBatch {
        host_mutation_id,
        value_arena,
        new_instances,
        mutations,
    })
}

fn instance_reference_is_zero(reference: NuxScreenInstanceReference) -> bool {
    reference.kind == 0 && reference.local_id == 0 && reference.instance_id == 0
}

fn copy_instance_reference(
    reference: NuxScreenInstanceReference,
) -> Result<OwnedInstanceReference, NuxStatus> {
    match reference.kind {
        NUX_SCREEN_INSTANCE_REFERENCE_KIND_EXISTING
            if reference.instance_id != 0 && reference.local_id == 0 =>
        {
            Ok(OwnedInstanceReference::Existing(reference.instance_id))
        }
        NUX_SCREEN_INSTANCE_REFERENCE_KIND_NEW if reference.instance_id == 0 => {
            Ok(OwnedInstanceReference::New(reference.local_id))
        }
        _ => Err(NuxStatus::InvalidArgument),
    }
}

fn optional_value_root(root_index: u32, arena: &OwnedValueArena) -> Result<Option<u32>, NuxStatus> {
    if root_index == NO_VALUE_ROOT {
        return Ok(None);
    }
    let index = usize::try_from(root_index).map_err(|_| NuxStatus::InvalidArgument)?;
    if index >= arena.nodes.len() {
        return Err(NuxStatus::InvalidArgument);
    }
    Ok(Some(root_index))
}

fn value_root_has_kind(
    root_index: Option<u32>,
    arena: &OwnedValueArena,
    expected_kind: NuxScreenValueKind,
) -> bool {
    root_index
        .and_then(|index| arena.nodes.get(index as usize))
        .is_some_and(|node| node.kind == expected_kind)
}

unsafe fn copy_text_run_batch(
    batch: *const NuxScreenTextRunBatch,
) -> Result<Vec<OwnedTextRunMutation>, NuxStatus> {
    if batch.is_null() {
        return Err(NuxStatus::NullArgument);
    }
    if unsafe { read_struct_size(batch) } != size_u32::<NuxScreenTextRunBatch>() {
        return Err(NuxStatus::InvalidArgument);
    }
    let batch = unsafe { batch.read() };
    let raw_mutations = unsafe {
        copy_array(
            batch.mutations,
            batch.mutation_count,
            NUX_SCREEN_MAX_BATCH_ITEM_COUNT,
        )?
    };
    let mut budget = PayloadBudget::default();
    let mut aggregate_text_bytes = 0_usize;
    let mut mutations = Vec::with_capacity(raw_mutations.len());
    for mutation in raw_mutations {
        if mutation.struct_size != size_u32::<NuxScreenTextRunMutation>() {
            return Err(NuxStatus::InvalidArgument);
        }
        let name = copy_required_utf8(mutation.name, NUX_SCREEN_MAX_ID_BYTE_LENGTH, &mut budget)?;
        let text = copy_bytes(
            mutation.text,
            NUX_SCREEN_MAX_STRING_BYTE_LENGTH,
            &mut budget,
        )?;
        if std::str::from_utf8(&text).is_err() {
            return Err(NuxStatus::InvalidArgument);
        }
        aggregate_text_bytes = aggregate_text_bytes
            .checked_add(text.len())
            .ok_or(NuxStatus::InvalidArgument)?;
        if aggregate_text_bytes > NUX_SCREEN_MAX_OPERATION_PAYLOAD_BYTE_LENGTH as usize {
            return Err(NuxStatus::InvalidArgument);
        }
        mutations.push(OwnedTextRunMutation { name, text });
    }
    Ok(mutations)
}

unsafe fn copy_pointer_batch(
    batch: *const NuxScreenPointerBatch,
) -> Result<Vec<OwnedPointerEvent>, NuxStatus> {
    if batch.is_null() {
        return Err(NuxStatus::NullArgument);
    }
    if unsafe { read_struct_size(batch) } != size_u32::<NuxScreenPointerBatch>() {
        return Err(NuxStatus::InvalidArgument);
    }
    let batch = unsafe { batch.read() };
    let raw_events = unsafe {
        copy_array(
            batch.events,
            batch.event_count,
            NUX_SCREEN_MAX_POINTER_COUNT,
        )?
    };
    if raw_events.is_empty() {
        return Err(NuxStatus::InvalidArgument);
    }
    let mut events = Vec::with_capacity(raw_events.len());
    for event in raw_events {
        if event.struct_size != size_u32::<NuxScreenPointerEvent>()
            || !event.x.is_finite()
            || !event.y.is_finite()
            || !event.timestamp_seconds.is_finite()
            || event.timestamp_seconds < 0.0
            || event.pointer_id <= 0
            || !matches!(
                event.kind,
                NUX_SCREEN_POINTER_EVENT_KIND_DOWN
                    | NUX_SCREEN_POINTER_EVENT_KIND_MOVE
                    | NUX_SCREEN_POINTER_EVENT_KIND_UP
                    | NUX_SCREEN_POINTER_EVENT_KIND_CANCEL
                    | NUX_SCREEN_POINTER_EVENT_KIND_EXIT
            )
        {
            return Err(NuxStatus::InvalidArgument);
        }
        events.push(OwnedPointerEvent {
            kind: event.kind,
            pointer_id: event.pointer_id,
            x: event.x,
            y: event.y,
            timestamp_seconds: event.timestamp_seconds,
        });
    }
    Ok(events)
}

unsafe fn copy_query_batch(
    batch: *const NuxScreenQueryBatch,
) -> Result<Vec<OwnedQuery>, NuxStatus> {
    if batch.is_null() {
        return Err(NuxStatus::NullArgument);
    }
    if unsafe { read_struct_size(batch) } != size_u32::<NuxScreenQueryBatch>() {
        return Err(NuxStatus::InvalidArgument);
    }
    let batch = unsafe { batch.read() };
    let raw_queries =
        unsafe { copy_array(batch.queries, batch.query_count, NUX_SCREEN_MAX_QUERY_COUNT)? };
    if raw_queries.is_empty() {
        return Err(NuxStatus::InvalidArgument);
    }
    let mut queries = Vec::with_capacity(raw_queries.len());
    for query in raw_queries {
        if query.struct_size != size_u32::<NuxScreenQuery>() {
            return Err(NuxStatus::InvalidArgument);
        }
        if !matches!(
            query.kind,
            NUX_SCREEN_QUERY_KIND_BOOTSTRAP
                | NUX_SCREEN_QUERY_KIND_VALUES
                | NUX_SCREEN_QUERY_KIND_CATALOG
                | NUX_SCREEN_QUERY_KIND_PLAYER_INPUTS
        ) {
            return Err(NuxStatus::InvalidArgument);
        }
        queries.push(OwnedQuery { kind: query.kind });
    }
    Ok(queries)
}

struct PendingAdvanceCompletion {
    callback: Option<unsafe extern "C" fn(context: *mut c_void)>,
    context_identity: usize,
}

impl PendingAdvanceCompletion {
    fn from_operation(operation: &NuxScreenAdvanceOperation) -> Result<Self, NuxStatus> {
        if operation.completion_callback.is_some() == operation.completion_context.is_null() {
            return Err(NuxStatus::InvalidArgument);
        }
        Ok(Self {
            callback: operation.completion_callback,
            context_identity: operation.completion_context.expose_provenance(),
        })
    }

    fn disarm(mut self) {
        self.callback = None;
    }
}

impl Drop for PendingAdvanceCompletion {
    fn drop(&mut self) {
        if let Some(callback) = self.callback.take() {
            unsafe {
                callback(ptr::with_exposed_provenance_mut(self.context_identity));
            }
        }
    }
}

unsafe fn copy_advance_operation(
    operation: *const NuxScreenAdvanceOperation,
) -> Result<OwnedAdvanceOperation, NuxStatus> {
    if operation.is_null() {
        return Err(NuxStatus::NullArgument);
    }
    if unsafe { read_struct_size(operation) } != size_u32::<NuxScreenAdvanceOperation>() {
        return Err(NuxStatus::InvalidArgument);
    }
    let operation = unsafe { operation.read() };
    let completion = PendingAdvanceCompletion::from_operation(&operation)?;
    let render = match operation.render {
        0 => false,
        1 => true,
        _ => return Err(NuxStatus::InvalidArgument),
    };
    if !operation.timestamp_seconds.is_finite()
        || operation.timestamp_seconds < 0.0
        || !operation.delta_seconds.is_finite()
        || operation.delta_seconds < 0.0
        || (!render && !operation.apple_drawable.is_null())
        || (operation.completion_callback.is_some() && operation.apple_drawable.is_null())
    {
        return Err(NuxStatus::InvalidArgument);
    }
    let owned = OwnedAdvanceOperation {
        timestamp_seconds: operation.timestamp_seconds,
        delta_seconds: operation.delta_seconds,
        render,
        drawable_identity: operation.apple_drawable.expose_provenance(),
        completion_context_identity: operation.completion_context.expose_provenance(),
        completion_callback: operation.completion_callback,
    };
    completion.disarm();
    Ok(owned)
}

unsafe fn copy_session_operation(
    operation: *const NuxScreenSessionOperation,
) -> Result<OwnedSessionOperation, NuxStatus> {
    if operation.is_null() {
        return Err(NuxStatus::NullArgument);
    }
    if unsafe { read_struct_size(operation) } != size_u32::<NuxScreenSessionOperation>() {
        return Err(NuxStatus::InvalidArgument);
    }
    let operation = unsafe { operation.read() };
    let selected_payload_count = [
        !operation.state_batch.is_null(),
        !operation.pointer_batch.is_null(),
        !operation.advance.is_null(),
        !operation.query_batch.is_null(),
        !operation.text_run_batch.is_null(),
    ]
    .into_iter()
    .filter(|selected| *selected)
    .count();
    if selected_payload_count != 1 {
        return Err(NuxStatus::InvalidArgument);
    }
    match operation.kind {
        NUX_SCREEN_SESSION_OPERATION_KIND_STATE_BATCH
            if !operation.state_batch.is_null()
                && operation.pointer_batch.is_null()
                && operation.advance.is_null()
                && operation.query_batch.is_null()
                && operation.text_run_batch.is_null() =>
        {
            unsafe { copy_state_batch(operation.state_batch) }
                .map(OwnedSessionOperation::StateBatch)
        }
        NUX_SCREEN_SESSION_OPERATION_KIND_POINTER_BATCH
            if operation.state_batch.is_null()
                && !operation.pointer_batch.is_null()
                && operation.advance.is_null()
                && operation.query_batch.is_null()
                && operation.text_run_batch.is_null() =>
        {
            unsafe { copy_pointer_batch(operation.pointer_batch) }
                .map(OwnedSessionOperation::PointerBatch)
        }
        NUX_SCREEN_SESSION_OPERATION_KIND_ADVANCE
            if operation.state_batch.is_null()
                && operation.pointer_batch.is_null()
                && !operation.advance.is_null()
                && operation.query_batch.is_null()
                && operation.text_run_batch.is_null() =>
        {
            unsafe { copy_advance_operation(operation.advance) }.map(OwnedSessionOperation::Advance)
        }
        NUX_SCREEN_SESSION_OPERATION_KIND_QUERY
            if operation.state_batch.is_null()
                && operation.pointer_batch.is_null()
                && operation.advance.is_null()
                && !operation.query_batch.is_null()
                && operation.text_run_batch.is_null() =>
        {
            unsafe { copy_query_batch(operation.query_batch) }.map(OwnedSessionOperation::Query)
        }
        NUX_SCREEN_SESSION_OPERATION_KIND_TEXT_RUN_BATCH
            if operation.state_batch.is_null()
                && operation.pointer_batch.is_null()
                && operation.advance.is_null()
                && operation.query_batch.is_null()
                && !operation.text_run_batch.is_null() =>
        {
            unsafe { copy_text_run_batch(operation.text_run_batch) }
                .map(OwnedSessionOperation::TextRunBatch)
        }
        _ => Err(NuxStatus::InvalidArgument),
    }
}

#[derive(Debug, Clone)]
struct OwnedPlayerMetadata {
    kind: NuxScreenPlayerKind,
    selection: NuxScreenPlayerSelection,
    player_index: Option<u32>,
    artboard_name: Vec<u8>,
    player_name: Vec<u8>,
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
}

#[derive(Debug, Clone)]
struct OwnedPlayerInput {
    kind: NuxScreenPlayerInputKind,
    value_root_index: u32,
    name: Vec<u8>,
}

#[derive(Debug, Clone)]
struct OwnedSchema {
    first_property: u32,
    property_count: u32,
    schema_id: Vec<u8>,
    name: Vec<u8>,
}

#[derive(Debug, Clone)]
struct OwnedSchemaProperty {
    kind: NuxScreenSchemaPropertyKind,
    first_enum_label: u32,
    enum_label_count: u32,
    schema_id: Vec<u8>,
    property_id: Vec<u8>,
    name: Vec<u8>,
    referenced_schema_id: Vec<u8>,
}

#[derive(Debug, Clone)]
struct OwnedEnumLabel {
    value: u32,
    label: Vec<u8>,
}

#[derive(Debug, Clone)]
struct OwnedInstanceTemplate {
    authored_index: u32,
    schema_id: Vec<u8>,
    authored_name: Vec<u8>,
}

#[derive(Debug, Clone)]
struct OwnedInstance {
    value_root_index: Option<u32>,
    instance_id: u64,
    is_root: bool,
    schema_id: Vec<u8>,
    name: Vec<u8>,
}

#[derive(Debug, Clone, Copy)]
struct OwnedValueRoot {
    value_root_index: u32,
    instance_id: u64,
}

#[derive(Debug, Clone, Copy)]
struct OwnedCreatedInstance {
    local_id: u32,
    instance_id: u64,
}

#[derive(Debug, Clone)]
struct OwnedOutput {
    phase: NuxScreenOutputPhase,
    kind: NuxScreenOutputKind,
    payload_root_index: Option<u32>,
    sequence: u64,
    cycle: u64,
    origin_mutation_id: Option<u64>,
    instance_id: Option<u64>,
    event_type: u32,
    first_event_property: u32,
    event_property_count: u32,
    delay_seconds: f32,
    name: Vec<u8>,
    path: Vec<u8>,
    payload: Vec<u8>,
    open_url: Option<OwnedOpenUrl>,
}

#[derive(Debug, Clone)]
struct OwnedOpenUrl {
    url: Vec<u8>,
    target: Vec<u8>,
}

#[derive(Debug, Clone)]
struct OwnedEventProperty {
    value_root_index: Option<u32>,
    trigger_count: Option<u64>,
    name: Vec<u8>,
}

#[derive(Clone)]
struct ScreenSessionResultHandle {
    status: NuxStatus,
    surface_disposition: NuxSurfaceDisposition,
    is_dirty: bool,
    is_settled: bool,
    wake_after: Option<f64>,
    player_metadata: Option<OwnedPlayerMetadata>,
    has_player_inputs: bool,
    player_inputs: Vec<OwnedPlayerInput>,
    has_catalog: bool,
    schemas: Vec<OwnedSchema>,
    schema_properties: Vec<OwnedSchemaProperty>,
    enum_labels: Vec<OwnedEnumLabel>,
    instance_templates: Vec<OwnedInstanceTemplate>,
    instances: Vec<OwnedInstance>,
    has_values: bool,
    value_arena: OwnedValueArena,
    value_roots: Vec<OwnedValueRoot>,
    created_instances: Vec<OwnedCreatedInstance>,
    outputs: Vec<OwnedOutput>,
    event_properties: Vec<OwnedEventProperty>,
    diagnostics: Vec<OwnedDiagnostic>,
}

impl ScreenSessionResultHandle {
    fn empty_success() -> Self {
        Self {
            status: NuxStatus::Ok,
            surface_disposition: NuxSurfaceDisposition::None,
            is_dirty: false,
            is_settled: false,
            wake_after: None,
            player_metadata: None,
            has_player_inputs: false,
            player_inputs: Vec::new(),
            has_catalog: false,
            schemas: Vec::new(),
            schema_properties: Vec::new(),
            enum_labels: Vec::new(),
            instance_templates: Vec::new(),
            instances: Vec::new(),
            has_values: false,
            value_arena: OwnedValueArena::default(),
            value_roots: Vec::new(),
            created_instances: Vec::new(),
            outputs: Vec::new(),
            event_properties: Vec::new(),
            diagnostics: Vec::new(),
        }
    }

    fn failure(status: NuxStatus, diagnostic: impl Into<Vec<u8>>) -> Self {
        Self::failure_with_code(status, diagnostic_code_for_status(status), diagnostic)
    }

    fn failure_with_code(
        status: NuxStatus,
        code: impl Into<Vec<u8>>,
        diagnostic: impl Into<Vec<u8>>,
    ) -> Self {
        let message = diagnostic.into();
        Self {
            status,
            surface_disposition: NuxSurfaceDisposition::Fatal,
            is_dirty: false,
            is_settled: false,
            wake_after: None,
            player_metadata: None,
            has_player_inputs: false,
            player_inputs: Vec::new(),
            has_catalog: false,
            schemas: Vec::new(),
            schema_properties: Vec::new(),
            enum_labels: Vec::new(),
            instance_templates: Vec::new(),
            instances: Vec::new(),
            has_values: false,
            value_arena: OwnedValueArena::default(),
            value_roots: Vec::new(),
            created_instances: Vec::new(),
            outputs: Vec::new(),
            event_properties: Vec::new(),
            diagnostics: vec![OwnedDiagnostic {
                severity: NUX_DIAGNOSTIC_SEVERITY_FATAL,
                code: code.into(),
                message,
            }],
        }
    }

    #[cfg(feature = "apple-product")]
    fn from_runtime_failure(failure: RuntimeFailure) -> Self {
        Self::failure_with_code(failure.status, failure.diagnostic_code, failure.diagnostic)
    }

    fn validate(&self) -> Result<(), NuxStatus> {
        if let Some(wake_after) = self.wake_after
            && (!wake_after.is_finite() || wake_after < 0.0)
        {
            return Err(NuxStatus::RuntimeError);
        }
        if self.schemas.len() > NUX_SCREEN_MAX_INSTANCE_COUNT as usize
            || self.player_inputs.len() > NUX_SCREEN_MAX_BATCH_ITEM_COUNT as usize
            || self.schema_properties.len() > NUX_SCREEN_MAX_BATCH_ITEM_COUNT as usize
            || self.enum_labels.len() > NUX_SCREEN_MAX_BATCH_ITEM_COUNT as usize
            || self.instance_templates.len() > NUX_SCREEN_MAX_INSTANCE_COUNT as usize
            || self.instances.len() > NUX_SCREEN_MAX_INSTANCE_COUNT as usize
            || self.value_roots.len() > NUX_SCREEN_MAX_INSTANCE_COUNT as usize
            || self.created_instances.len() > NUX_SCREEN_MAX_INSTANCE_COUNT as usize
            || self.outputs.len() > NUX_SCREEN_MAX_OUTPUT_COUNT as usize
            || self.event_properties.len()
                > (NUX_SCREEN_MAX_OUTPUT_COUNT * NUX_SCREEN_MAX_EVENT_PROPERTY_COUNT) as usize
            || self.value_arena.nodes.len() > NUX_SCREEN_MAX_BATCH_ITEM_COUNT as usize
            || self.value_arena.edges.len() > NUX_SCREEN_MAX_VALUE_EDGE_COUNT as usize
        {
            return Err(NuxStatus::RuntimeError);
        }
        for node in &self.value_arena.nodes {
            validate_result_value_node(node)?;
        }
        validate_value_graph(&self.value_arena.nodes, &self.value_arena.edges)
            .map_err(|_| NuxStatus::RuntimeError)?;
        let mut payload_bytes = 0usize;
        if let Some(metadata) = self.player_metadata.as_ref() {
            let selection_is_consistent = match metadata.selection {
                NUX_SCREEN_PLAYER_SELECTION_EXPLICIT_STATE_MACHINE
                | NUX_SCREEN_PLAYER_SELECTION_AUTHORED_DEFAULT_STATE_MACHINE
                | NUX_SCREEN_PLAYER_SELECTION_FIRST_STATE_MACHINE => {
                    metadata.kind == NUX_SCREEN_PLAYER_KIND_STATE_MACHINE
                        && metadata.player_index.is_some()
                }
                NUX_SCREEN_PLAYER_SELECTION_FIRST_ANIMATION
                | NUX_SCREEN_PLAYER_SELECTION_EXPLICIT_LINEAR_ANIMATION => {
                    metadata.kind == NUX_SCREEN_PLAYER_KIND_LINEAR_ANIMATION
                        && metadata.player_index.is_some()
                }
                NUX_SCREEN_PLAYER_SELECTION_STATIC => {
                    metadata.kind == NUX_SCREEN_PLAYER_KIND_STATIC
                        && metadata.player_index.is_none()
                }
                _ => false,
            };
            if !selection_is_consistent
                || !metadata.min_x.is_finite()
                || !metadata.min_y.is_finite()
                || !metadata.max_x.is_finite()
                || !metadata.max_y.is_finite()
                || metadata.max_x < metadata.min_x
                || metadata.max_y < metadata.min_y
            {
                return Err(NuxStatus::RuntimeError);
            }
            charge_result_utf8(
                &mut payload_bytes,
                &metadata.artboard_name,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
            charge_result_utf8(
                &mut payload_bytes,
                &metadata.player_name,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
        }
        for input in &self.player_inputs {
            let expected_value_kind = match input.kind {
                NUX_SCREEN_PLAYER_INPUT_KIND_BOOL | NUX_SCREEN_PLAYER_INPUT_KIND_TRIGGER => {
                    NUX_SCREEN_VALUE_KIND_BOOL
                }
                NUX_SCREEN_PLAYER_INPUT_KIND_NUMBER => NUX_SCREEN_VALUE_KIND_NUMBER,
                _ => return Err(NuxStatus::RuntimeError),
            };
            if self
                .value_arena
                .nodes
                .get(input.value_root_index as usize)
                .is_none_or(|node| node.kind != expected_value_kind)
            {
                return Err(NuxStatus::RuntimeError);
            }
            charge_result_utf8(
                &mut payload_bytes,
                &input.name,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
        }
        for schema in &self.schemas {
            let first = schema.first_property as usize;
            let count = schema.property_count as usize;
            let end = first.checked_add(count).ok_or(NuxStatus::RuntimeError)?;
            if end > self.schema_properties.len() || schema.schema_id.is_empty() {
                return Err(NuxStatus::RuntimeError);
            }
            charge_result_utf8(
                &mut payload_bytes,
                &schema.schema_id,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
            charge_result_utf8(
                &mut payload_bytes,
                &schema.name,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
        }
        for property in &self.schema_properties {
            let first_enum_label = property.first_enum_label as usize;
            let enum_label_count = property.enum_label_count as usize;
            let enum_label_end = first_enum_label
                .checked_add(enum_label_count)
                .ok_or(NuxStatus::RuntimeError)?;
            if !matches!(
                property.kind,
                NUX_SCREEN_SCHEMA_PROPERTY_KIND_STRING
                    | NUX_SCREEN_SCHEMA_PROPERTY_KIND_NUMBER
                    | NUX_SCREEN_SCHEMA_PROPERTY_KIND_BOOL
                    | NUX_SCREEN_SCHEMA_PROPERTY_KIND_TRIGGER
                    | NUX_SCREEN_SCHEMA_PROPERTY_KIND_ENUM
                    | NUX_SCREEN_SCHEMA_PROPERTY_KIND_LIST_INDEX
                    | NUX_SCREEN_SCHEMA_PROPERTY_KIND_COLOR
                    | NUX_SCREEN_SCHEMA_PROPERTY_KIND_IMAGE
                    | NUX_SCREEN_SCHEMA_PROPERTY_KIND_VIEW_MODEL
                    | NUX_SCREEN_SCHEMA_PROPERTY_KIND_LIST
                    | NUX_SCREEN_SCHEMA_PROPERTY_KIND_OBJECT
                    | NUX_SCREEN_SCHEMA_PROPERTY_KIND_NULL
            ) || property.schema_id.is_empty()
                || property.property_id.is_empty()
                || enum_label_end > self.enum_labels.len()
                || (enum_label_count == 0 && first_enum_label != 0)
                || (property.kind != NUX_SCREEN_SCHEMA_PROPERTY_KIND_ENUM && enum_label_count != 0)
                || (property.kind == NUX_SCREEN_SCHEMA_PROPERTY_KIND_VIEW_MODEL
                    && property.referenced_schema_id.is_empty())
                || (property.kind != NUX_SCREEN_SCHEMA_PROPERTY_KIND_VIEW_MODEL
                    && !property.referenced_schema_id.is_empty())
            {
                return Err(NuxStatus::RuntimeError);
            }
            if !property.referenced_schema_id.is_empty()
                && !self
                    .schemas
                    .iter()
                    .any(|schema| schema.schema_id == property.referenced_schema_id)
            {
                return Err(NuxStatus::RuntimeError);
            }
            let labels = self
                .enum_labels
                .get(first_enum_label..enum_label_end)
                .ok_or(NuxStatus::RuntimeError)?;
            for (offset, label) in labels.iter().enumerate() {
                if label.value != offset as u32 {
                    return Err(NuxStatus::RuntimeError);
                }
            }
            charge_result_utf8(
                &mut payload_bytes,
                &property.schema_id,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
            charge_result_utf8(
                &mut payload_bytes,
                &property.property_id,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
            charge_result_utf8(
                &mut payload_bytes,
                &property.name,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
            charge_result_utf8(
                &mut payload_bytes,
                &property.referenced_schema_id,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
        }
        for label in &self.enum_labels {
            charge_result_utf8(
                &mut payload_bytes,
                &label.label,
                NUX_SCREEN_MAX_STRING_BYTE_LENGTH,
            )?;
        }
        for template in &self.instance_templates {
            if template.schema_id.is_empty() {
                return Err(NuxStatus::RuntimeError);
            }
            charge_result_utf8(
                &mut payload_bytes,
                &template.schema_id,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
            charge_result_utf8(
                &mut payload_bytes,
                &template.authored_name,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
        }
        let mut instance_ids = HashSet::with_capacity(self.instances.len());
        for instance in &self.instances {
            if instance.instance_id == 0
                || instance.schema_id.is_empty()
                || !instance_ids.insert(instance.instance_id)
            {
                return Err(NuxStatus::RuntimeError);
            }
            if let Some(root) = instance.value_root_index
                && root as usize >= self.value_arena.nodes.len()
            {
                return Err(NuxStatus::RuntimeError);
            }
            charge_result_utf8(
                &mut payload_bytes,
                &instance.schema_id,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
            charge_result_utf8(
                &mut payload_bytes,
                &instance.name,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
        }
        let mut root_instance_ids = HashSet::with_capacity(self.value_roots.len());
        for root in &self.value_roots {
            if root.instance_id == 0
                || !root_instance_ids.insert(root.instance_id)
                || root.value_root_index as usize >= self.value_arena.nodes.len()
            {
                return Err(NuxStatus::RuntimeError);
            }
        }
        let mut created_local_ids = HashSet::with_capacity(self.created_instances.len());
        let mut created_instance_ids = HashSet::with_capacity(self.created_instances.len());
        for created in &self.created_instances {
            if created.instance_id == 0
                || !created_local_ids.insert(created.local_id)
                || !created_instance_ids.insert(created.instance_id)
            {
                return Err(NuxStatus::RuntimeError);
            }
        }
        for node in &self.value_arena.nodes {
            charge_result_utf8(
                &mut payload_bytes,
                &node.string_value,
                NUX_SCREEN_MAX_STRING_BYTE_LENGTH,
            )?;
            charge_result_utf8(
                &mut payload_bytes,
                &node.schema_id,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
        }
        for edge in &self.value_arena.edges {
            charge_result_utf8(
                &mut payload_bytes,
                &edge.key,
                NUX_SCREEN_MAX_PATH_BYTE_LENGTH,
            )?;
        }
        let mut prior_sequence = None;
        let mut prior_cycle_phase = None;
        let mut host_cycle = None;
        let mut host_commands_this_cycle = 0_usize;
        let mut host_content_bytes_this_cycle = 0_usize;
        for output in &self.outputs {
            if output.instance_id == Some(0) {
                return Err(NuxStatus::RuntimeError);
            }
            if !matches!(
                output.phase,
                NUX_SCREEN_OUTPUT_PHASE_DELAYED_EVENT_CALLBACKS
                    | NUX_SCREEN_OUTPUT_PHASE_REPORTED_EVENTS
                    | NUX_SCREEN_OUTPUT_PHASE_RUNTIME_ADVANCE
                    | NUX_SCREEN_OUTPUT_PHASE_VIEW_MODEL_CHANGES
                    | NUX_SCREEN_OUTPUT_PHASE_HOST_WORK
                    | NUX_SCREEN_OUTPUT_PHASE_RENDER
            ) || !matches!(
                output.kind,
                NUX_SCREEN_OUTPUT_KIND_REPORTED_EVENT
                    | NUX_SCREEN_OUTPUT_KIND_STATE_CHANGE
                    | NUX_SCREEN_OUTPUT_KIND_VIEW_MODEL_CHANGE
                    | NUX_SCREEN_OUTPUT_KIND_HOST_COMMAND
                    | NUX_SCREEN_OUTPUT_KIND_RENDER_REQUEST
                    | NUX_SCREEN_OUTPUT_KIND_RUNTIME_ADVANCED
            ) {
                return Err(NuxStatus::RuntimeError);
            }
            if prior_sequence.is_some_and(|sequence| output.sequence <= sequence) {
                return Err(NuxStatus::RuntimeError);
            }
            if let Some((cycle, phase)) = prior_cycle_phase
                && (output.cycle < cycle || (output.cycle == cycle && output.phase < phase))
            {
                return Err(NuxStatus::RuntimeError);
            }
            if let Some(root) = output.payload_root_index {
                let node = self
                    .value_arena
                    .nodes
                    .get(root as usize)
                    .ok_or(NuxStatus::RuntimeError)?;
                let is_scalar = matches!(
                    node.kind,
                    NUX_SCREEN_VALUE_KIND_NULL
                        | NUX_SCREEN_VALUE_KIND_STRING
                        | NUX_SCREEN_VALUE_KIND_NUMBER
                        | NUX_SCREEN_VALUE_KIND_BOOL
                        | NUX_SCREEN_VALUE_KIND_ENUM
                        | NUX_SCREEN_VALUE_KIND_COLOR
                        | NUX_SCREEN_VALUE_KIND_IMAGE
                        | NUX_SCREEN_VALUE_KIND_LIST_INDEX
                );
                let is_view_model_reference = node.kind == NUX_SCREEN_VALUE_KIND_VIEW_MODEL
                    && node.edge_count == 0
                    && node.instance_id.is_some_and(|instance_id| instance_id != 0)
                    && !node.schema_id.is_empty();
                let valid_payload_root = match output.kind {
                    NUX_SCREEN_OUTPUT_KIND_STATE_CHANGE => is_scalar,
                    NUX_SCREEN_OUTPUT_KIND_VIEW_MODEL_CHANGE => {
                        is_scalar || is_view_model_reference
                    }
                    NUX_SCREEN_OUTPUT_KIND_HOST_COMMAND => {
                        node.kind == NUX_SCREEN_VALUE_KIND_OBJECT
                            && node.instance_id.is_none()
                            && node.schema_id.is_empty()
                    }
                    _ => false,
                };
                if !valid_payload_root {
                    return Err(NuxStatus::RuntimeError);
                }
            }
            if output.kind == NUX_SCREEN_OUTPUT_KIND_HOST_COMMAND {
                let content_bytes = validate_host_command_output(output, &self.value_arena)?;
                if host_cycle != Some(output.cycle) {
                    host_cycle = Some(output.cycle);
                    host_commands_this_cycle = 0;
                    host_content_bytes_this_cycle = 0;
                }
                host_commands_this_cycle = host_commands_this_cycle
                    .checked_add(1)
                    .ok_or(NuxStatus::RuntimeError)?;
                host_content_bytes_this_cycle = host_content_bytes_this_cycle
                    .checked_add(content_bytes)
                    .ok_or(NuxStatus::RuntimeError)?;
                if host_commands_this_cycle > NUX_SCREEN_MAX_HOST_COMMANDS_PER_CYCLE
                    || host_content_bytes_this_cycle
                        > NUX_SCREEN_MAX_OPERATION_PAYLOAD_BYTE_LENGTH as usize
                {
                    return Err(NuxStatus::RuntimeError);
                }
            }
            if !output.delay_seconds.is_finite() || output.delay_seconds < 0.0 {
                return Err(NuxStatus::RuntimeError);
            }
            let property_start = output.first_event_property as usize;
            let property_count = output.event_property_count as usize;
            let property_end = property_start
                .checked_add(property_count)
                .ok_or(NuxStatus::RuntimeError)?;
            if property_count > NUX_SCREEN_MAX_EVENT_PROPERTY_COUNT as usize
                || property_end > self.event_properties.len()
                || (output.kind != NUX_SCREEN_OUTPUT_KIND_REPORTED_EVENT && property_count != 0)
            {
                return Err(NuxStatus::RuntimeError);
            }
            charge_result_utf8(
                &mut payload_bytes,
                &output.name,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
            charge_result_utf8(
                &mut payload_bytes,
                &output.path,
                NUX_SCREEN_MAX_PATH_BYTE_LENGTH,
            )?;
            charge_result_bytes(
                &mut payload_bytes,
                &output.payload,
                NUX_SCREEN_MAX_OPERATION_PAYLOAD_BYTE_LENGTH,
            )?;
            if let Some(open_url) = &output.open_url {
                if output.kind != NUX_SCREEN_OUTPUT_KIND_REPORTED_EVENT {
                    return Err(NuxStatus::RuntimeError);
                }
                if !matches!(
                    open_url.target.as_slice(),
                    b"" | b"_blank" | b"_parent" | b"_self" | b"_top"
                ) {
                    return Err(NuxStatus::RuntimeError);
                }
                charge_result_utf8(
                    &mut payload_bytes,
                    &open_url.url,
                    NUX_SCREEN_MAX_STRING_BYTE_LENGTH,
                )?;
                charge_result_utf8(
                    &mut payload_bytes,
                    &open_url.target,
                    NUX_SCREEN_MAX_ID_BYTE_LENGTH,
                )?;
            }
            prior_sequence = Some(output.sequence);
            prior_cycle_phase = Some((output.cycle, output.phase));
        }
        for property in &self.event_properties {
            if (property.value_root_index.is_some() == property.trigger_count.is_some())
                || property
                    .value_root_index
                    .is_some_and(|root| root as usize >= self.value_arena.nodes.len())
            {
                return Err(NuxStatus::RuntimeError);
            }
            charge_result_utf8(
                &mut payload_bytes,
                &property.name,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
        }
        for diagnostic in &self.diagnostics {
            charge_result_utf8(
                &mut payload_bytes,
                &diagnostic.code,
                NUX_SCREEN_MAX_ID_BYTE_LENGTH,
            )?;
            charge_result_utf8(
                &mut payload_bytes,
                &diagnostic.message,
                NUX_SCREEN_MAX_STRING_BYTE_LENGTH,
            )?;
        }
        Ok(())
    }
}

#[derive(Default)]
struct HostValueValidation {
    visited: HashSet<u32>,
    nodes: usize,
    edges: usize,
    content_bytes: usize,
}

fn validate_host_command_output(
    output: &OwnedOutput,
    arena: &OwnedValueArena,
) -> Result<usize, NuxStatus> {
    if output.phase != NUX_SCREEN_OUTPUT_PHASE_HOST_WORK
        || !output.path.is_empty()
        || !output.payload.is_empty()
        || output.origin_mutation_id.is_some()
        || output.instance_id.is_some()
        || output.event_type != 0
        || output.first_event_property != 0
        || output.event_property_count != 0
        || output.delay_seconds.to_bits() != 0
        || output.open_url.is_some()
        || output.name.is_empty()
        || output.name.len() > NUX_SCREEN_MAX_ID_BYTE_LENGTH as usize
        || std::str::from_utf8(&output.name).is_err()
    {
        return Err(NuxStatus::RuntimeError);
    }
    let root = output.payload_root_index.ok_or(NuxStatus::RuntimeError)?;
    if arena
        .nodes
        .get(root as usize)
        .is_none_or(|node| node.kind != NUX_SCREEN_VALUE_KIND_OBJECT)
    {
        return Err(NuxStatus::RuntimeError);
    }

    let mut validation = HostValueValidation {
        content_bytes: output.name.len(),
        ..HostValueValidation::default()
    };
    validate_host_value_tree(root, 1, arena, &mut validation)?;
    Ok(validation.content_bytes)
}

fn validate_host_value_tree(
    node_index: u32,
    depth: u32,
    arena: &OwnedValueArena,
    validation: &mut HostValueValidation,
) -> Result<(), NuxStatus> {
    if depth > NUX_SCREEN_MAX_VALUE_DEPTH || !validation.visited.insert(node_index) {
        return Err(NuxStatus::RuntimeError);
    }
    validation.nodes = validation
        .nodes
        .checked_add(1)
        .ok_or(NuxStatus::RuntimeError)?;
    if validation.nodes > NUX_SCREEN_MAX_BATCH_ITEM_COUNT as usize {
        return Err(NuxStatus::RuntimeError);
    }

    let node = arena
        .nodes
        .get(node_index as usize)
        .ok_or(NuxStatus::RuntimeError)?;
    let first_edge = node.first_edge as usize;
    let edge_count = node.edge_count as usize;
    let end_edge = first_edge
        .checked_add(edge_count)
        .ok_or(NuxStatus::RuntimeError)?;
    let edges = arena
        .edges
        .get(first_edge..end_edge)
        .ok_or(NuxStatus::RuntimeError)?;

    match node.kind {
        NUX_SCREEN_VALUE_KIND_BOOL | NUX_SCREEN_VALUE_KIND_NUMBER => {
            validation.content_bytes = validation
                .content_bytes
                .checked_add(16)
                .ok_or(NuxStatus::RuntimeError)?;
        }
        NUX_SCREEN_VALUE_KIND_STRING => {
            validation.content_bytes = validation
                .content_bytes
                .checked_add(node.string_value.len())
                .ok_or(NuxStatus::RuntimeError)?;
        }
        NUX_SCREEN_VALUE_KIND_LIST => {
            if edge_count > NUX_SCREEN_MAX_LIST_ITEM_COUNT as usize
                || !node.schema_id.is_empty()
                || node.instance_id.is_some()
                || edges.iter().any(|edge| !edge.key.is_empty())
            {
                return Err(NuxStatus::RuntimeError);
            }
            validation.edges = validation
                .edges
                .checked_add(edge_count)
                .ok_or(NuxStatus::RuntimeError)?;
            if validation.edges > NUX_SCREEN_MAX_VALUE_EDGE_COUNT as usize {
                return Err(NuxStatus::RuntimeError);
            }
            for edge in edges {
                validate_host_value_tree(
                    edge.node_index,
                    depth.checked_add(1).ok_or(NuxStatus::RuntimeError)?,
                    arena,
                    validation,
                )?;
            }
        }
        NUX_SCREEN_VALUE_KIND_OBJECT => {
            if edge_count > NUX_SCREEN_MAX_LIST_ITEM_COUNT as usize
                || !node.schema_id.is_empty()
                || node.instance_id.is_some()
            {
                return Err(NuxStatus::RuntimeError);
            }
            validation.edges = validation
                .edges
                .checked_add(edge_count)
                .ok_or(NuxStatus::RuntimeError)?;
            if validation.edges > NUX_SCREEN_MAX_VALUE_EDGE_COUNT as usize {
                return Err(NuxStatus::RuntimeError);
            }
            let mut prior_key: Option<&[u8]> = None;
            for edge in edges {
                let key = edge.key.as_slice();
                if key.is_empty()
                    || key.len() > NUX_SCREEN_MAX_ID_BYTE_LENGTH as usize
                    || std::str::from_utf8(key).is_err()
                    || prior_key.is_some_and(|prior| prior >= key)
                {
                    return Err(NuxStatus::RuntimeError);
                }
                validation.content_bytes = validation
                    .content_bytes
                    .checked_add(key.len())
                    .ok_or(NuxStatus::RuntimeError)?;
                prior_key = Some(key);
                validate_host_value_tree(
                    edge.node_index,
                    depth.checked_add(1).ok_or(NuxStatus::RuntimeError)?,
                    arena,
                    validation,
                )?;
            }
        }
        _ => return Err(NuxStatus::RuntimeError),
    }
    if validation.content_bytes > NUX_SCREEN_MAX_OPERATION_PAYLOAD_BYTE_LENGTH as usize {
        return Err(NuxStatus::RuntimeError);
    }
    Ok(())
}

fn validate_result_value_node(node: &OwnedValueNode) -> Result<(), NuxStatus> {
    let has_edges = node.edge_count != 0;
    let canonical_edge_start = has_edges || node.first_edge == 0;
    let number_is_zero = node.number_value.to_bits() == 0;
    let common_composite = number_is_zero
        && node.color_value == 0
        && !node.bool_value
        && node.identity_value == 0
        && node.string_value.is_empty()
        && canonical_edge_start;
    let valid = match node.kind {
        NUX_SCREEN_VALUE_KIND_NULL => {
            common_composite
                && !has_edges
                && node.instance_id.is_none()
                && node.schema_id.is_empty()
        }
        NUX_SCREEN_VALUE_KIND_STRING => {
            number_is_zero
                && node.color_value == 0
                && !node.bool_value
                && node.identity_value == 0
                && node.instance_id.is_none()
                && node.schema_id.is_empty()
                && !has_edges
                && canonical_edge_start
        }
        NUX_SCREEN_VALUE_KIND_NUMBER => {
            node.number_value.is_finite()
                && node.color_value == 0
                && !node.bool_value
                && node.identity_value == 0
                && node.string_value.is_empty()
                && node.instance_id.is_none()
                && node.schema_id.is_empty()
                && !has_edges
                && canonical_edge_start
        }
        NUX_SCREEN_VALUE_KIND_BOOL => {
            number_is_zero
                && node.color_value == 0
                && node.identity_value == 0
                && node.string_value.is_empty()
                && node.instance_id.is_none()
                && node.schema_id.is_empty()
                && !has_edges
                && canonical_edge_start
        }
        NUX_SCREEN_VALUE_KIND_COLOR => {
            number_is_zero
                && !node.bool_value
                && node.identity_value == 0
                && node.string_value.is_empty()
                && node.instance_id.is_none()
                && node.schema_id.is_empty()
                && !has_edges
                && canonical_edge_start
        }
        NUX_SCREEN_VALUE_KIND_ENUM
        | NUX_SCREEN_VALUE_KIND_IMAGE
        | NUX_SCREEN_VALUE_KIND_LIST_INDEX => {
            number_is_zero
                && node.color_value == 0
                && !node.bool_value
                && node.string_value.is_empty()
                && node.instance_id.is_none()
                && node.schema_id.is_empty()
                && !has_edges
                && canonical_edge_start
        }
        NUX_SCREEN_VALUE_KIND_OBJECT => common_composite && node.instance_id.is_none(),
        NUX_SCREEN_VALUE_KIND_VIEW_MODEL => {
            common_composite && node.instance_id.is_none_or(|instance_id| instance_id != 0)
        }
        NUX_SCREEN_VALUE_KIND_LIST => {
            common_composite && node.instance_id.is_none() && node.schema_id.is_empty()
        }
        _ => false,
    };
    if valid {
        Ok(())
    } else {
        Err(NuxStatus::RuntimeError)
    }
}

fn charge_result_utf8(total: &mut usize, bytes: &[u8], maximum: u64) -> Result<(), NuxStatus> {
    if std::str::from_utf8(bytes).is_err() {
        return Err(NuxStatus::RuntimeError);
    }
    charge_result_bytes(total, bytes, maximum)
}

fn charge_result_bytes(total: &mut usize, bytes: &[u8], maximum: u64) -> Result<(), NuxStatus> {
    if bytes.len() > maximum as usize {
        return Err(NuxStatus::RuntimeError);
    }
    *total = total
        .checked_add(bytes.len())
        .ok_or(NuxStatus::RuntimeError)?;
    if *total > NUX_SCREEN_MAX_OPERATION_PAYLOAD_BYTE_LENGTH as usize {
        return Err(NuxStatus::RuntimeError);
    }
    Ok(())
}

fn borrowed_view(bytes: &[u8]) -> NuxByteView {
    if bytes.is_empty() {
        return NuxByteView::default();
    }
    NuxByteView {
        data: bytes.as_ptr(),
        len: u64::try_from(bytes.len()).unwrap_or(u64::MAX),
    }
}

fn replace_session_result(
    out_result: *mut *mut NuxScreenSessionResult,
    mut result: ScreenSessionResultHandle,
) -> NuxStatus {
    if out_result.is_null() {
        return result.status;
    }
    if result.validate().is_err() {
        result = ScreenSessionResultHandle::failure(
            NuxStatus::RuntimeError,
            "runtime produced an invalid or oversized session result",
        );
    }
    let status = result.status;
    unsafe {
        *out_result = Box::into_raw(Box::new(result)).cast();
    }
    status
}

fn write_session_failure(
    out_result: *mut *mut NuxScreenSessionResult,
    status: NuxStatus,
    diagnostic: impl Into<Vec<u8>>,
) -> NuxStatus {
    replace_session_result(
        out_result,
        ScreenSessionResultHandle::failure(status, diagnostic),
    )
}

#[cfg(feature = "apple-product")]
fn write_session_runtime_failure(
    out_result: *mut *mut NuxScreenSessionResult,
    failure: RuntimeFailure,
) -> NuxStatus {
    replace_session_result(
        out_result,
        ScreenSessionResultHandle::from_runtime_failure(failure),
    )
}

fn reset_session_result(out_result: *mut *mut NuxScreenSessionResult) {
    if !out_result.is_null() {
        unsafe {
            *out_result = ptr::null_mut();
        }
    }
}

fn ffi_guard_with_session_result(
    out_result: *mut *mut NuxScreenSessionResult,
    on_panic: impl FnOnce(),
    body: impl FnOnce() -> NuxStatus,
) -> NuxStatus {
    match panic::catch_unwind(AssertUnwindSafe(body)) {
        Ok(status) => status,
        Err(_) => {
            let _ = panic::catch_unwind(AssertUnwindSafe(on_panic));
            reset_session_result(out_result);
            write_session_failure(out_result, NuxStatus::RuntimeError, PANIC_DIAGNOSTIC)
        }
    }
}

#[cfg(feature = "apple-product")]
mod configured_session_seam {
    use super::*;
    use nuxie::flow_session as core;

    pub(super) fn create(
        context: &ExperienceRuntimeContextHandle,
        descriptor: OwnedConfiguredSessionDescriptor,
    ) -> Result<(Box<ScreenSessionHandle>, ScreenSessionResultHandle), RuntimeFailure> {
        let worker = Arc::clone(&context.worker);
        let creation = worker.call(None, move |state| create_on_worker(state, descriptor));
        let (session_id, result) = match creation {
            Ok(result) => result?,
            Err(WorkerCallError::Panicked) => {
                return Err(RuntimeFailure::runtime(PANIC_DIAGNOSTIC));
            }
            Err(WorkerCallError::Unavailable) => {
                return Err(RuntimeFailure::runtime("runtime worker is unavailable"));
            }
        };
        let handle = Box::new(ScreenSessionHandle {
            token: Arc::new(SessionToken {
                worker,
                id: session_id,
            }),
        });
        Ok((handle, result))
    }

    fn create_on_worker(
        state: &mut WorkerState,
        descriptor: OwnedConfiguredSessionDescriptor,
    ) -> Result<(SessionId, ScreenSessionResultHandle), RuntimeFailure> {
        let player = descriptor.player.map(|selector| match selector {
            OwnedPlayerSelector::StateMachine(name) => core::FlowPlayerSelector::StateMachine(name),
            OwnedPlayerSelector::LinearAnimation(name) => {
                core::FlowPlayerSelector::LinearAnimation(name)
            }
        });
        let config = core::FlowSessionConfig {
            artboard_name: descriptor.artboard_name,
            player,
        };
        let mut factory = state.make_session_factory()?;
        let renderer_generation = state.gpu_generation;
        let (session, creation) = core::FlowSession::create_with_factory(
            Arc::clone(&state.file),
            config,
            factory.as_mut(),
        )
        .map_err(runtime_failure_from_core)?;
        let mut result = result_from_bootstrap(&creation.bootstrap)?;
        result.is_dirty = creation.dirty;
        result.is_settled = creation.settled;
        result.wake_after = creation.wake_after_seconds.map(f64::from);
        append_outputs(&mut result, creation.outputs)?;
        result
            .validate()
            .map_err(|_| RuntimeFailure::runtime("bootstrap exceeds published bounds"))?;
        let session_id = state.allocate_session_id()?;
        state.sessions.insert(
            session_id,
            SessionState {
                is_fatal: false,
                fatal_diagnostic: None,
                screen_session: session,
                factory,
                renderer_generation,
                legacy_timestamp_seconds: 0.0,
                #[cfg(test)]
                render_attempts: 0,
                #[cfg(test)]
                injected_device_loss: false,
                #[cfg(test)]
                panic_on_next_configured_operation: false,
                attachment: None,
            },
        );
        Ok((session_id, result))
    }

    pub(super) fn perform(
        session: *const NuxScreenSession,
        operation: OwnedSessionOperation,
    ) -> (NuxStatus, ScreenSessionResultHandle) {
        let handle = unsafe { &*session.cast::<ScreenSessionHandle>() };
        let session_id = handle.token.id;
        match handle.token.worker.call(Some(session_id), move |state| {
            perform_on_worker(state, session_id, operation)
        }) {
            Ok(Ok(result)) => (NuxStatus::Ok, result),
            Ok(Err(failure)) => {
                let result = ScreenSessionResultHandle::from_runtime_failure(failure);
                (result.status, result)
            }
            Err(WorkerCallError::Panicked) => (
                NuxStatus::RuntimeError,
                ScreenSessionResultHandle::failure(NuxStatus::RuntimeError, PANIC_DIAGNOSTIC),
            ),
            Err(WorkerCallError::Unavailable) => (
                NuxStatus::RuntimeError,
                ScreenSessionResultHandle::failure(
                    NuxStatus::RuntimeError,
                    "runtime worker is unavailable",
                ),
            ),
        }
    }

    fn perform_on_worker(
        state: &mut WorkerState,
        session_id: SessionId,
        operation: OwnedSessionOperation,
    ) -> Result<ScreenSessionResultHandle, RuntimeFailure> {
        state.require_live_session(session_id)?;
        #[cfg(test)]
        {
            let session = state.session_mut(session_id)?;
            if std::mem::take(&mut session.panic_on_next_configured_operation) {
                panic!("deliberate configured-session operation panic probe");
            }
        }
        if let OwnedSessionOperation::Advance(advance) = operation {
            return perform_advance_on_worker(state, session_id, advance);
        }
        let session = state.session_mut(session_id)?;
        let screen_session = &mut session.screen_session;
        let factory = &mut session.factory;
        let core_result = match operation {
            OwnedSessionOperation::Query(queries) => {
                let mut combined = ScreenSessionResultHandle::empty_success();
                let mut deferred_player_inputs = None;
                for query in queries {
                    let query = match query.kind {
                        NUX_SCREEN_QUERY_KIND_BOOTSTRAP => core::FlowQuery::Bootstrap,
                        NUX_SCREEN_QUERY_KIND_VALUES => core::FlowQuery::Values,
                        NUX_SCREEN_QUERY_KIND_CATALOG => core::FlowQuery::Catalog,
                        NUX_SCREEN_QUERY_KIND_PLAYER_INPUTS => core::FlowQuery::PlayerInputs,
                        _ => {
                            return Err(RuntimeFailure::new(
                                NuxStatus::InvalidArgument,
                                "unknown query kind",
                            ));
                        }
                    };
                    let mut result = screen_session
                        .perform_with_factory(core::FlowOperation::Query(query), factory.as_mut())
                        .map_err(runtime_failure_from_core)?;
                    if result.player_inputs.is_some() {
                        deferred_player_inputs = result.player_inputs.take();
                    }
                    merge_core_result(&mut combined, result)?;
                }
                if let Some(inputs) = deferred_player_inputs {
                    replace_player_inputs(&mut combined, inputs)?;
                    combined.has_player_inputs = true;
                    combined.validate().map_err(|_| {
                        RuntimeFailure::runtime("query result exceeds published bounds")
                    })?;
                }
                return Ok(combined);
            }
            OwnedSessionOperation::StateBatch(batch) => {
                core::FlowOperation::StateBatch(state_batch_to_core(batch)?)
            }
            OwnedSessionOperation::PointerBatch(events) => {
                core::FlowOperation::PointerBatch(core::FlowPointerBatch {
                    events: events
                        .into_iter()
                        .map(|event| {
                            Ok(core::FlowPointerEvent {
                                kind: pointer_kind_to_core(event.kind)?,
                                pointer_id: event.pointer_id,
                                x: event.x,
                                y: event.y,
                                timestamp_seconds: event.timestamp_seconds,
                            })
                        })
                        .collect::<Result<Vec<_>, RuntimeFailure>>()?,
                })
            }
            OwnedSessionOperation::TextRunBatch(mutations) => {
                core::FlowOperation::TextRunBatch(core::FlowTextRunBatch {
                    mutations: mutations
                        .into_iter()
                        .map(|mutation| {
                            Ok(core::FlowTextRunMutation {
                                name: String::from_utf8(mutation.name).map_err(|_| {
                                    RuntimeFailure::new(
                                        NuxStatus::InvalidArgument,
                                        "text-run name is not UTF-8",
                                    )
                                })?,
                                text: String::from_utf8(mutation.text).map_err(|_| {
                                    RuntimeFailure::new(
                                        NuxStatus::InvalidArgument,
                                        "text-run value is not UTF-8",
                                    )
                                })?,
                            })
                        })
                        .collect::<Result<Vec<_>, RuntimeFailure>>()?,
                })
            }
            OwnedSessionOperation::Advance(_) => {
                return Err(RuntimeFailure::runtime("advance dispatch is inconsistent"));
            }
        };
        let result = screen_session
            .perform_with_factory(core_result, factory.as_mut())
            .map_err(runtime_failure_from_core)?;
        result_from_core(result)
    }

    fn perform_advance_on_worker(
        state: &mut WorkerState,
        session_id: SessionId,
        mut advance: OwnedAdvanceOperation,
    ) -> Result<ScreenSessionResultHandle, RuntimeFailure> {
        let completion = PendingFrameCompletion {
            callback: advance.completion_callback.take(),
            context_identity: advance.completion_context_identity,
        };
        let session = state.session_mut(session_id)?;
        let preflight_disposition = if advance.render {
            session.preflight_present(advance.drawable_identity != 0)?
        } else {
            None
        };
        if matches!(preflight_disposition, Some(SurfaceDisposition::DeviceLost)) {
            let mut result = ScreenSessionResultHandle::empty_success();
            result.surface_disposition = NUX_SURFACE_DISPOSITION_DEVICE_LOST;
            result.is_settled = session.screen_session.is_settled();
            return Ok(result);
        }
        let mut core_result = session
            .screen_session
            .perform_with_factory(
                core::FlowOperation::Advance(core::FlowAdvance {
                    timestamp_seconds: advance.timestamp_seconds,
                    delta_seconds: advance.delta_seconds,
                    render: advance.render,
                }),
                session.factory.as_mut(),
            )
            .map_err(runtime_failure_from_core)?;
        session.legacy_timestamp_seconds = advance.timestamp_seconds;
        if !advance.render {
            return committed_result_from_core(session, core_result);
        }
        if let Some(disposition) = preflight_disposition {
            let mut result = committed_result_from_core(session, core_result)?;
            result.surface_disposition = surface_disposition(disposition);
            return Ok(result);
        }
        let Some((viewport_width, viewport_height)) = session
            .attachment
            .as_ref()
            .map(|attachment| attachment.surface.dimensions())
        else {
            let failure = RuntimeFailure::runtime("preflighted surface became unavailable");
            return Err(terminalize_after_committed_advance_failure(
                session,
                "presentation setup",
                failure,
            ));
        };
        let bounds = session.screen_session.artboard_bounds();
        let presentation_transform = match centered_contain_transform(
            bounds.x,
            bounds.y,
            bounds.width,
            bounds.height,
            viewport_width,
            viewport_height,
        ) {
            Ok(transform) => transform,
            Err(failure) => {
                return Err(terminalize_after_committed_advance_failure(
                    session,
                    "presentation transform",
                    failure,
                ));
            }
        };
        let mut frame = session.factory.begin_frame(0x0000_0000);
        frame.transform(presentation_transform);
        #[cfg(test)]
        {
            session.render_attempts = session.render_attempts.saturating_add(1);
        }
        let draw_result = session.screen_session.draw_into_result(
            session.factory.as_mut(),
            &mut frame,
            &mut core_result,
        );
        if let Err(error) = draw_result {
            let failure = runtime_failure_from_core(error);
            return Err(terminalize_after_committed_advance_failure(
                session, "drawing", failure,
            ));
        }
        let drawable = ptr::with_exposed_provenance_mut::<c_void>(advance.drawable_identity);
        let completion = completion.into_renderer_completion();
        let presentation = {
            let Some(attachment) = session.attachment.as_mut() else {
                let failure = RuntimeFailure::runtime("preflighted surface became unavailable");
                return Err(terminalize_after_committed_advance_failure(
                    session,
                    "presentation setup",
                    failure,
                ));
            };
            unsafe {
                attachment
                    .surface
                    .present(&mut session.factory, frame, drawable, completion)
            }
        };
        let (disposition, _metrics) = match presentation {
            Ok(presentation) => presentation,
            Err(error) => {
                let failure = RuntimeFailure::surface(format!("{error:#}"));
                return Err(terminalize_after_committed_advance_failure(
                    session,
                    "presentation",
                    failure,
                ));
            }
        };
        let mut result = committed_result_from_core(session, core_result)?;
        result.surface_disposition = surface_disposition(disposition);
        Ok(result)
    }

    fn committed_result_from_core(
        session: &mut SessionState,
        result: core::FlowResult,
    ) -> Result<ScreenSessionResultHandle, RuntimeFailure> {
        result_from_core(result).map_err(|failure| {
            terminalize_after_committed_advance_failure(session, "result translation", failure)
        })
    }

    fn runtime_failure_from_core(error: core::FlowSessionError) -> RuntimeFailure {
        RuntimeFailure::screen_session(error.kind(), error.message())
    }

    fn state_batch_to_core(batch: OwnedStateBatch) -> Result<core::FlowStateBatch, RuntimeFailure> {
        let OwnedStateBatch {
            host_mutation_id,
            value_arena,
            new_instances,
            mutations,
        } = batch;
        let new_instances = new_instances
            .into_iter()
            .map(|instance| {
                let schema_name = String::from_utf8(instance.schema_name).map_err(|_| {
                    RuntimeFailure::new(
                        NuxStatus::InvalidArgument,
                        "new-instance schema name is not UTF-8",
                    )
                })?;
                let authored_instance_name = instance
                    .authored_instance_name
                    .map(String::from_utf8)
                    .transpose()
                    .map_err(|_| {
                        RuntimeFailure::new(
                            NuxStatus::InvalidArgument,
                            "new-instance authored name is not UTF-8",
                        )
                    })?;
                Ok(core::FlowNewInstance {
                    local_id: instance.local_id,
                    schema_name,
                    authored_instance_name,
                })
            })
            .collect::<Result<Vec<_>, RuntimeFailure>>()?;
        let mutations = mutations
            .into_iter()
            .map(|mutation| mutation_to_core(mutation, &value_arena))
            .collect::<Result<Vec<_>, _>>()?;
        Ok(core::FlowStateBatch {
            host_mutation_id,
            mutations,
            new_instances,
        })
    }

    fn pointer_kind_to_core(
        kind: NuxScreenPointerEventKind,
    ) -> Result<core::FlowPointerKind, RuntimeFailure> {
        match kind {
            NUX_SCREEN_POINTER_EVENT_KIND_DOWN => Ok(core::FlowPointerKind::Down),
            NUX_SCREEN_POINTER_EVENT_KIND_MOVE => Ok(core::FlowPointerKind::Move),
            NUX_SCREEN_POINTER_EVENT_KIND_UP => Ok(core::FlowPointerKind::Up),
            NUX_SCREEN_POINTER_EVENT_KIND_CANCEL => Ok(core::FlowPointerKind::Cancel),
            NUX_SCREEN_POINTER_EVENT_KIND_EXIT => Ok(core::FlowPointerKind::Exit),
            _ => Err(RuntimeFailure::new(
                NuxStatus::InvalidArgument,
                "unknown pointer event kind",
            )),
        }
    }

    fn mutation_to_core(
        mutation: OwnedStateMutation,
        arena: &OwnedValueArena,
    ) -> Result<core::FlowStateMutation, RuntimeFailure> {
        let OwnedStateMutation {
            kind,
            instance,
            item,
            path,
            input_name,
            value_root_index,
            index,
            other_index,
        } = mutation;
        if matches!(
            kind,
            NUX_SCREEN_STATE_MUTATION_KIND_SET_INPUT_BOOL
                | NUX_SCREEN_STATE_MUTATION_KIND_SET_INPUT_NUMBER
                | NUX_SCREEN_STATE_MUTATION_KIND_FIRE_INPUT_TRIGGER
        ) {
            let name = String::from_utf8(input_name.ok_or_else(|| {
                RuntimeFailure::new(
                    NuxStatus::InvalidArgument,
                    "player-input mutation has no input name",
                )
            })?)
            .map_err(|_| {
                RuntimeFailure::new(NuxStatus::InvalidArgument, "player-input name is not UTF-8")
            })?;
            return match kind {
                NUX_SCREEN_STATE_MUTATION_KIND_SET_INPUT_BOOL => {
                    let core::FlowScalarValue::Bool(value) =
                        scalar_value_at(arena, value_root_index)?
                    else {
                        return Err(RuntimeFailure::new(
                            NuxStatus::InvalidArgument,
                            "bool input mutation requires a bool value",
                        ));
                    };
                    Ok(core::FlowStateMutation::SetInputBool { name, value })
                }
                NUX_SCREEN_STATE_MUTATION_KIND_SET_INPUT_NUMBER => {
                    let core::FlowScalarValue::Number(value) =
                        scalar_value_at(arena, value_root_index)?
                    else {
                        return Err(RuntimeFailure::new(
                            NuxStatus::InvalidArgument,
                            "number input mutation requires a number value",
                        ));
                    };
                    Ok(core::FlowStateMutation::SetInputNumber { name, value })
                }
                NUX_SCREEN_STATE_MUTATION_KIND_FIRE_INPUT_TRIGGER => {
                    Ok(core::FlowStateMutation::FireInputTrigger { name })
                }
                _ => Err(RuntimeFailure::new(
                    NuxStatus::InvalidArgument,
                    "unknown player-input mutation kind",
                )),
            };
        }
        let instance = instance_reference_to_core(instance.ok_or_else(|| {
            RuntimeFailure::new(
                NuxStatus::InvalidArgument,
                "view-model mutation has no instance",
            )
        })?)?;
        let path = String::from_utf8(path.ok_or_else(|| {
            RuntimeFailure::new(
                NuxStatus::InvalidArgument,
                "view-model mutation has no path",
            )
        })?)
        .map_err(|_| {
            RuntimeFailure::new(NuxStatus::InvalidArgument, "mutation path is not UTF-8")
        })?;
        match kind {
            NUX_SCREEN_STATE_MUTATION_KIND_SET => Ok(core::FlowStateMutation::SetValue {
                instance,
                path,
                value: scalar_value_at(arena, value_root_index)?,
            }),
            NUX_SCREEN_STATE_MUTATION_KIND_TRIGGER => {
                Ok(core::FlowStateMutation::FireTrigger { instance, path })
            }
            NUX_SCREEN_STATE_MUTATION_KIND_SET_VIEW_MODEL => {
                Ok(core::FlowStateMutation::SetViewModel {
                    instance,
                    path,
                    value: instance_reference_to_core(item.ok_or_else(|| {
                        RuntimeFailure::new(
                            NuxStatus::InvalidArgument,
                            "view-model replacement value is missing",
                        )
                    })?)?,
                })
            }
            NUX_SCREEN_STATE_MUTATION_KIND_LIST_INSERT => Ok(core::FlowStateMutation::ListInsert {
                instance,
                path,
                index: index as usize,
                item: instance_reference_to_core(item.ok_or_else(|| {
                    RuntimeFailure::new(NuxStatus::InvalidArgument, "list insert item is missing")
                })?)?,
            }),
            NUX_SCREEN_STATE_MUTATION_KIND_LIST_REMOVE => Ok(core::FlowStateMutation::ListRemove {
                instance,
                path,
                index: index as usize,
            }),
            NUX_SCREEN_STATE_MUTATION_KIND_LIST_SWAP => Ok(core::FlowStateMutation::ListSwap {
                instance,
                path,
                first: index as usize,
                second: other_index as usize,
            }),
            NUX_SCREEN_STATE_MUTATION_KIND_LIST_MOVE => Ok(core::FlowStateMutation::ListMove {
                instance,
                path,
                from: index as usize,
                to: other_index as usize,
            }),
            NUX_SCREEN_STATE_MUTATION_KIND_LIST_SET => Ok(core::FlowStateMutation::ListSet {
                instance,
                path,
                index: index as usize,
                item: instance_reference_to_core(item.ok_or_else(|| {
                    RuntimeFailure::new(NuxStatus::InvalidArgument, "list set item is missing")
                })?)?,
            }),
            NUX_SCREEN_STATE_MUTATION_KIND_LIST_CLEAR => {
                Ok(core::FlowStateMutation::ListClear { instance, path })
            }
            _ => Err(RuntimeFailure::new(
                NuxStatus::InvalidArgument,
                "unknown mutation kind",
            )),
        }
    }

    fn instance_reference_to_core(
        reference: OwnedInstanceReference,
    ) -> Result<core::FlowInstanceRef, RuntimeFailure> {
        match reference {
            OwnedInstanceReference::Existing(id) => core::FlowInstanceId::new(id)
                .map(core::FlowInstanceRef::Existing)
                .ok_or_else(|| {
                    RuntimeFailure::new(NuxStatus::InvalidArgument, "instance ID zero is reserved")
                }),
            OwnedInstanceReference::New(local_id) => Ok(core::FlowInstanceRef::New(local_id)),
        }
    }

    fn scalar_value_at(
        arena: &OwnedValueArena,
        root: Option<u32>,
    ) -> Result<core::FlowScalarValue, RuntimeFailure> {
        let root = root.ok_or_else(|| {
            RuntimeFailure::new(NuxStatus::InvalidArgument, "set mutation has no value")
        })?;
        let node = arena.nodes.get(root as usize).ok_or_else(|| {
            RuntimeFailure::new(NuxStatus::InvalidArgument, "set value root is out of range")
        })?;
        match node.kind {
            NUX_SCREEN_VALUE_KIND_NULL => Ok(core::FlowScalarValue::Null),
            NUX_SCREEN_VALUE_KIND_STRING => String::from_utf8(node.string_value.clone())
                .map(core::FlowScalarValue::String)
                .map_err(|_| {
                    RuntimeFailure::new(NuxStatus::InvalidArgument, "string value is not UTF-8")
                }),
            NUX_SCREEN_VALUE_KIND_NUMBER => {
                Ok(core::FlowScalarValue::Number(node.number_value as f32))
            }
            NUX_SCREEN_VALUE_KIND_BOOL => Ok(core::FlowScalarValue::Bool(node.bool_value)),
            NUX_SCREEN_VALUE_KIND_ENUM => Ok(core::FlowScalarValue::Enum(node.identity_value)),
            NUX_SCREEN_VALUE_KIND_LIST_INDEX => {
                Ok(core::FlowScalarValue::ListIndex(node.identity_value))
            }
            NUX_SCREEN_VALUE_KIND_COLOR => Ok(core::FlowScalarValue::Color(node.color_value)),
            NUX_SCREEN_VALUE_KIND_IMAGE => Ok(core::FlowScalarValue::Image(node.identity_value)),
            _ => Err(RuntimeFailure::new(
                NuxStatus::InvalidArgument,
                "set values must be scalar",
            )),
        }
    }

    fn result_from_bootstrap(
        bootstrap: &core::FlowBootstrap,
    ) -> Result<ScreenSessionResultHandle, RuntimeFailure> {
        let max_x = bootstrap.bounds.x + bootstrap.bounds.width;
        let max_y = bootstrap.bounds.y + bootstrap.bounds.height;
        if !max_x.is_finite() || !max_y.is_finite() {
            return Err(RuntimeFailure::runtime("artboard bounds overflowed"));
        }
        let mut result = ScreenSessionResultHandle::empty_success();
        result.player_metadata = Some(OwnedPlayerMetadata {
            kind: player_kind_from_core(bootstrap.player.kind),
            selection: player_selection_from_core(bootstrap.player.selection),
            player_index: bootstrap
                .player
                .index
                .map(u32::try_from)
                .transpose()
                .map_err(|_| RuntimeFailure::runtime("player index overflowed"))?,
            artboard_name: bootstrap
                .artboard_name
                .as_deref()
                .unwrap_or_default()
                .as_bytes()
                .to_vec(),
            player_name: bootstrap
                .player
                .name
                .as_deref()
                .unwrap_or_default()
                .as_bytes()
                .to_vec(),
            min_x: bootstrap.bounds.x,
            min_y: bootstrap.bounds.y,
            max_x,
            max_y,
        });
        append_value_arena(&mut result, &bootstrap.values)?;
        result.has_values = true;
        replace_catalog(&mut result, &bootstrap.catalog)?;
        result.has_catalog = true;
        synchronize_instance_roots(&mut result);
        Ok(result)
    }

    fn player_kind_from_core(kind: core::FlowPlayerKind) -> NuxScreenPlayerKind {
        match kind {
            core::FlowPlayerKind::StateMachine => NUX_SCREEN_PLAYER_KIND_STATE_MACHINE,
            core::FlowPlayerKind::LinearAnimation => NUX_SCREEN_PLAYER_KIND_LINEAR_ANIMATION,
            core::FlowPlayerKind::Static => NUX_SCREEN_PLAYER_KIND_STATIC,
        }
    }

    fn player_selection_from_core(
        selection: core::FlowPlayerSelection,
    ) -> NuxScreenPlayerSelection {
        match selection {
            core::FlowPlayerSelection::ExplicitStateMachine => {
                NUX_SCREEN_PLAYER_SELECTION_EXPLICIT_STATE_MACHINE
            }
            core::FlowPlayerSelection::AuthoredDefaultStateMachine => {
                NUX_SCREEN_PLAYER_SELECTION_AUTHORED_DEFAULT_STATE_MACHINE
            }
            core::FlowPlayerSelection::FirstStateMachine => {
                NUX_SCREEN_PLAYER_SELECTION_FIRST_STATE_MACHINE
            }
            core::FlowPlayerSelection::FirstAnimation => {
                NUX_SCREEN_PLAYER_SELECTION_FIRST_ANIMATION
            }
            core::FlowPlayerSelection::Static => NUX_SCREEN_PLAYER_SELECTION_STATIC,
            core::FlowPlayerSelection::ExplicitLinearAnimation => {
                NUX_SCREEN_PLAYER_SELECTION_EXPLICIT_LINEAR_ANIMATION
            }
        }
    }

    fn replace_catalog(
        result: &mut ScreenSessionResultHandle,
        catalog: &core::FlowCatalog,
    ) -> Result<(), RuntimeFailure> {
        result.schemas.clear();
        result.schema_properties.clear();
        result.enum_labels.clear();
        result.instance_templates.clear();
        result.instances.clear();
        for schema in &catalog.schemas {
            let first_property = u32::try_from(result.schema_properties.len())
                .map_err(|_| RuntimeFailure::runtime("schema property index overflowed"))?;
            for property in &schema.properties {
                let first_enum_label = if property.enum_labels.is_empty() {
                    0
                } else {
                    u32::try_from(result.enum_labels.len())
                        .map_err(|_| RuntimeFailure::runtime("enum label index overflowed"))?
                };
                for (value, label) in property.enum_labels.iter().enumerate() {
                    result.enum_labels.push(OwnedEnumLabel {
                        value: u32::try_from(value)
                            .map_err(|_| RuntimeFailure::runtime("enum value overflowed"))?,
                        label: label.as_bytes().to_vec(),
                    });
                }
                result.schema_properties.push(OwnedSchemaProperty {
                    kind: schema_property_kind_from_core(property.value_type),
                    first_enum_label,
                    enum_label_count: u32::try_from(property.enum_labels.len())
                        .map_err(|_| RuntimeFailure::runtime("enum label count overflowed"))?,
                    schema_id: schema.name.as_bytes().to_vec(),
                    property_id: property.name.as_bytes().to_vec(),
                    name: property.name.as_bytes().to_vec(),
                    referenced_schema_id: property
                        .referenced_schema_name
                        .as_deref()
                        .unwrap_or_default()
                        .as_bytes()
                        .to_vec(),
                });
            }
            let property_count = u32::try_from(schema.properties.len())
                .map_err(|_| RuntimeFailure::runtime("schema property count overflowed"))?;
            result.schemas.push(OwnedSchema {
                first_property,
                property_count,
                schema_id: schema.name.as_bytes().to_vec(),
                name: schema.name.as_bytes().to_vec(),
            });
        }
        for template in &catalog.templates {
            result.instance_templates.push(OwnedInstanceTemplate {
                authored_index: u32::try_from(template.authored_index)
                    .map_err(|_| RuntimeFailure::runtime("authored instance index overflowed"))?,
                schema_id: template.schema_name.as_bytes().to_vec(),
                authored_name: template
                    .authored_name
                    .as_deref()
                    .unwrap_or_default()
                    .as_bytes()
                    .to_vec(),
            });
        }
        for instance in &catalog.instances {
            result.instances.push(OwnedInstance {
                value_root_index: None,
                instance_id: instance.id.get(),
                is_root: instance.is_root,
                schema_id: instance.schema_name.as_bytes().to_vec(),
                name: instance
                    .authored_name
                    .as_deref()
                    .unwrap_or_default()
                    .as_bytes()
                    .to_vec(),
            });
        }
        Ok(())
    }

    fn schema_property_kind_from_core(kind: core::FlowValueType) -> NuxScreenSchemaPropertyKind {
        match kind {
            core::FlowValueType::Null => NUX_SCREEN_SCHEMA_PROPERTY_KIND_NULL,
            core::FlowValueType::String => NUX_SCREEN_SCHEMA_PROPERTY_KIND_STRING,
            core::FlowValueType::Number => NUX_SCREEN_SCHEMA_PROPERTY_KIND_NUMBER,
            core::FlowValueType::Bool => NUX_SCREEN_SCHEMA_PROPERTY_KIND_BOOL,
            core::FlowValueType::Enum => NUX_SCREEN_SCHEMA_PROPERTY_KIND_ENUM,
            core::FlowValueType::ListIndex => NUX_SCREEN_SCHEMA_PROPERTY_KIND_LIST_INDEX,
            core::FlowValueType::Color => NUX_SCREEN_SCHEMA_PROPERTY_KIND_COLOR,
            core::FlowValueType::Image => NUX_SCREEN_SCHEMA_PROPERTY_KIND_IMAGE,
            core::FlowValueType::Object => NUX_SCREEN_SCHEMA_PROPERTY_KIND_OBJECT,
            core::FlowValueType::ViewModel => NUX_SCREEN_SCHEMA_PROPERTY_KIND_VIEW_MODEL,
            core::FlowValueType::List => NUX_SCREEN_SCHEMA_PROPERTY_KIND_LIST,
            core::FlowValueType::Trigger => NUX_SCREEN_SCHEMA_PROPERTY_KIND_TRIGGER,
        }
    }

    fn append_value_arena(
        result: &mut ScreenSessionResultHandle,
        arena: &core::FlowValueArena,
    ) -> Result<(), RuntimeFailure> {
        let mut indexes = HashMap::with_capacity(arena.nodes.len());
        for (index, node) in arena.nodes.iter().enumerate() {
            let index = result
                .value_arena
                .nodes
                .len()
                .checked_add(index)
                .and_then(|index| u32::try_from(index).ok())
                .ok_or_else(|| RuntimeFailure::runtime("value node index overflowed"))?;
            if indexes.insert(node.id.get(), index).is_some() {
                return Err(RuntimeFailure::runtime(
                    "value arena contains duplicate node IDs",
                ));
            }
        }
        for node in &arena.nodes {
            let first_edge = u32::try_from(result.value_arena.edges.len())
                .map_err(|_| RuntimeFailure::runtime("value edge index overflowed"))?;
            let (kind, number_value, color_value, bool_value, identity_value, string_value) =
                match &node.value {
                    core::FlowValue::Null => {
                        (NUX_SCREEN_VALUE_KIND_NULL, 0.0, 0, false, 0, Vec::new())
                    }
                    core::FlowValue::String(value) => (
                        NUX_SCREEN_VALUE_KIND_STRING,
                        0.0,
                        0,
                        false,
                        0,
                        value.as_bytes().to_vec(),
                    ),
                    core::FlowValue::Number(value) => (
                        NUX_SCREEN_VALUE_KIND_NUMBER,
                        f64::from(*value),
                        0,
                        false,
                        0,
                        Vec::new(),
                    ),
                    core::FlowValue::Bool(value) => {
                        (NUX_SCREEN_VALUE_KIND_BOOL, 0.0, 0, *value, 0, Vec::new())
                    }
                    core::FlowValue::Enum(value) => (
                        NUX_SCREEN_VALUE_KIND_ENUM,
                        0.0,
                        0,
                        false,
                        *value,
                        Vec::new(),
                    ),
                    core::FlowValue::ListIndex(value) => (
                        NUX_SCREEN_VALUE_KIND_LIST_INDEX,
                        0.0,
                        0,
                        false,
                        *value,
                        Vec::new(),
                    ),
                    core::FlowValue::Color(value) => (
                        NUX_SCREEN_VALUE_KIND_COLOR,
                        0.0,
                        *value,
                        false,
                        0,
                        Vec::new(),
                    ),
                    core::FlowValue::Image(value) => (
                        NUX_SCREEN_VALUE_KIND_IMAGE,
                        0.0,
                        0,
                        false,
                        *value,
                        Vec::new(),
                    ),
                    core::FlowValue::Object(children) => {
                        append_named_edges(&mut result.value_arena.edges, children, &indexes)?;
                        (NUX_SCREEN_VALUE_KIND_OBJECT, 0.0, 0, false, 0, Vec::new())
                    }
                    core::FlowValue::ViewModel(children) => {
                        append_named_edges(&mut result.value_arena.edges, children, &indexes)?;
                        (
                            NUX_SCREEN_VALUE_KIND_VIEW_MODEL,
                            0.0,
                            0,
                            false,
                            0,
                            Vec::new(),
                        )
                    }
                    core::FlowValue::List(children) => {
                        for child in children {
                            let node_index = *indexes.get(&child.get()).ok_or_else(|| {
                                RuntimeFailure::runtime("value edge references a missing node")
                            })?;
                            result.value_arena.edges.push(OwnedValueEdge {
                                node_index,
                                key: Vec::new(),
                            });
                        }
                        (NUX_SCREEN_VALUE_KIND_LIST, 0.0, 0, false, 0, Vec::new())
                    }
                };
            let edge_count = u32::try_from(result.value_arena.edges.len())
                .ok()
                .and_then(|end| end.checked_sub(first_edge))
                .ok_or_else(|| RuntimeFailure::runtime("value edge count overflowed"))?;
            let first_edge = if edge_count == 0 { 0 } else { first_edge };
            result.value_arena.nodes.push(OwnedValueNode {
                kind,
                number_value,
                color_value,
                bool_value,
                first_edge,
                edge_count,
                instance_id: None,
                identity_value,
                string_value,
                schema_id: Vec::new(),
            });
        }
        for (instance, root) in &arena.roots {
            let value_root_index = *indexes
                .get(&root.get())
                .ok_or_else(|| RuntimeFailure::runtime("value root references a missing node"))?;
            if let Some(node) = result.value_arena.nodes.get_mut(value_root_index as usize)
                && node.kind == NUX_SCREEN_VALUE_KIND_VIEW_MODEL
            {
                node.instance_id = Some(instance.get());
            }
            result.value_roots.push(OwnedValueRoot {
                value_root_index,
                instance_id: instance.get(),
            });
        }
        Ok(())
    }

    fn append_named_edges(
        output: &mut Vec<OwnedValueEdge>,
        children: &[(String, core::FlowValueId)],
        indexes: &HashMap<u32, u32>,
    ) -> Result<(), RuntimeFailure> {
        for (key, child) in children {
            let node_index = *indexes
                .get(&child.get())
                .ok_or_else(|| RuntimeFailure::runtime("value edge references a missing node"))?;
            output.push(OwnedValueEdge {
                node_index,
                key: key.as_bytes().to_vec(),
            });
        }
        Ok(())
    }

    fn synchronize_instance_roots(result: &mut ScreenSessionResultHandle) {
        for instance in &mut result.instances {
            instance.value_root_index = result
                .value_roots
                .iter()
                .find(|root| root.instance_id == instance.instance_id)
                .map(|root| root.value_root_index);
        }
        for root in &result.value_roots {
            let schema_id = result
                .instances
                .iter()
                .find(|instance| instance.instance_id == root.instance_id)
                .map(|instance| instance.schema_id.clone())
                .unwrap_or_default();
            if let Some(node) = result
                .value_arena
                .nodes
                .get_mut(root.value_root_index as usize)
                && node.kind == NUX_SCREEN_VALUE_KIND_VIEW_MODEL
            {
                node.instance_id = Some(root.instance_id);
                node.schema_id = schema_id;
            }
        }
    }

    pub(super) fn result_from_core(
        result: core::FlowResult,
    ) -> Result<ScreenSessionResultHandle, RuntimeFailure> {
        let mut translated = ScreenSessionResultHandle::empty_success();
        merge_core_result(&mut translated, result)?;
        Ok(translated)
    }

    fn merge_core_result(
        translated: &mut ScreenSessionResultHandle,
        result: core::FlowResult,
    ) -> Result<(), RuntimeFailure> {
        translated.is_dirty = result.dirty;
        translated.is_settled = result.settled;
        translated.wake_after = result.wake_after_seconds.map(f64::from);
        if let Some(snapshot) = result.snapshot.as_ref() {
            let bootstrap = result_from_bootstrap(snapshot)?;
            translated.player_metadata = bootstrap.player_metadata;
            translated.has_catalog = bootstrap.has_catalog;
            translated.schemas = bootstrap.schemas;
            translated.schema_properties = bootstrap.schema_properties;
            translated.enum_labels = bootstrap.enum_labels;
            translated.instance_templates = bootstrap.instance_templates;
            translated.instances = bootstrap.instances;
            translated.has_values = bootstrap.has_values;
            translated.value_arena = bootstrap.value_arena;
            translated.value_roots = bootstrap.value_roots;
        }
        if let Some(values) = result.values.as_ref() {
            translated.value_arena = OwnedValueArena::default();
            translated.value_roots.clear();
            append_value_arena(translated, values)?;
            translated.has_values = true;
        }
        if let Some(catalog) = result.catalog.as_ref() {
            replace_catalog(translated, catalog)?;
            translated.has_catalog = true;
        }
        if let Some(inputs) = result.player_inputs {
            replace_player_inputs(translated, inputs)?;
            translated.has_player_inputs = true;
        }
        synchronize_instance_roots(translated);
        translated
            .created_instances
            .extend(
                result
                    .created_instances
                    .into_iter()
                    .map(|created| OwnedCreatedInstance {
                        local_id: created.local_id,
                        instance_id: created.id.get(),
                    }),
            );
        append_outputs(translated, result.outputs)?;
        translated
            .validate()
            .map_err(|_| RuntimeFailure::runtime("flow result exceeds published bounds"))?;
        Ok(())
    }

    fn replace_player_inputs(
        result: &mut ScreenSessionResultHandle,
        inputs: Vec<core::FlowInputSnapshot>,
    ) -> Result<(), RuntimeFailure> {
        result.player_inputs.clear();
        for input in inputs {
            let kind = match input.kind {
                nuxie::StateMachineInputKind::Bool => NUX_SCREEN_PLAYER_INPUT_KIND_BOOL,
                nuxie::StateMachineInputKind::Number => NUX_SCREEN_PLAYER_INPUT_KIND_NUMBER,
                nuxie::StateMachineInputKind::Trigger => NUX_SCREEN_PLAYER_INPUT_KIND_TRIGGER,
            };
            let value_root_index = push_scalar(result, input.value)?;
            result.player_inputs.push(OwnedPlayerInput {
                kind,
                value_root_index,
                name: input.name.unwrap_or_default().into_bytes(),
            });
        }
        Ok(())
    }

    fn append_outputs(
        result: &mut ScreenSessionResultHandle,
        outputs: Vec<core::FlowOutput>,
    ) -> Result<(), RuntimeFailure> {
        for output in outputs {
            let phase = match output.phase {
                core::FlowOutputPhase::DelayedEventCallbacks => {
                    NUX_SCREEN_OUTPUT_PHASE_DELAYED_EVENT_CALLBACKS
                }
                core::FlowOutputPhase::ReportedEvents => NUX_SCREEN_OUTPUT_PHASE_REPORTED_EVENTS,
                core::FlowOutputPhase::RuntimeAdvance => NUX_SCREEN_OUTPUT_PHASE_RUNTIME_ADVANCE,
                core::FlowOutputPhase::ViewModelChanges => {
                    NUX_SCREEN_OUTPUT_PHASE_VIEW_MODEL_CHANGES
                }
                core::FlowOutputPhase::HostWork => NUX_SCREEN_OUTPUT_PHASE_HOST_WORK,
                core::FlowOutputPhase::Render => NUX_SCREEN_OUTPUT_PHASE_RENDER,
            };
            let mut translated = OwnedOutput {
                phase,
                // Every payload branch below overwrites this placeholder.
                kind: NUX_SCREEN_OUTPUT_KIND_REPORTED_EVENT,
                payload_root_index: None,
                sequence: output.sequence,
                cycle: output.cycle,
                origin_mutation_id: None,
                instance_id: None,
                event_type: 0,
                first_event_property: 0,
                event_property_count: 0,
                delay_seconds: 0.0,
                name: Vec::new(),
                path: Vec::new(),
                payload: Vec::new(),
                open_url: None,
            };
            match output.payload {
                core::FlowOutputPayload::ReportedEvent {
                    name,
                    event_type,
                    url,
                    target,
                    delay_seconds,
                    properties,
                } => {
                    translated.kind = NUX_SCREEN_OUTPUT_KIND_REPORTED_EVENT;
                    let open_url = match (url, target) {
                        (Some(url), Some(target)) => Some(OwnedOpenUrl {
                            url: url.into_bytes(),
                            target: target.into_bytes(),
                        }),
                        (None, None) => None,
                        _ => {
                            return Err(RuntimeFailure::runtime(
                                "OpenURL event URL and target presence must match",
                            ));
                        }
                    };
                    populate_event_output(
                        result,
                        &mut translated,
                        name,
                        event_type,
                        open_url,
                        delay_seconds,
                        properties,
                    )?;
                }
                core::FlowOutputPayload::StateChanged {
                    instance_id,
                    path,
                    value,
                    origin_mutation_id,
                } => {
                    translated.kind = if instance_id.is_some() {
                        NUX_SCREEN_OUTPUT_KIND_VIEW_MODEL_CHANGE
                    } else {
                        NUX_SCREEN_OUTPUT_KIND_STATE_CHANGE
                    };
                    translated.instance_id = instance_id.map(core::FlowInstanceId::get);
                    translated.path = path.into_bytes();
                    translated.origin_mutation_id = origin_mutation_id;
                    if let Some(value) = value {
                        translated.payload_root_index =
                            Some(push_state_change_value(result, value)?);
                    }
                }
                core::FlowOutputPayload::HostCommand { name, payload } => {
                    translated.kind = NUX_SCREEN_OUTPUT_KIND_HOST_COMMAND;
                    translated.name = name.into_bytes();
                    translated.payload_root_index = Some(push_host_value(result, payload)?);
                }
                core::FlowOutputPayload::RenderRequested { .. } => {
                    translated.kind = NUX_SCREEN_OUTPUT_KIND_RENDER_REQUEST;
                }
                core::FlowOutputPayload::RuntimeAdvanced { delta_seconds } => {
                    translated.kind = NUX_SCREEN_OUTPUT_KIND_RUNTIME_ADVANCED;
                    translated.delay_seconds = delta_seconds;
                }
            }
            result.outputs.push(translated);
        }
        Ok(())
    }

    fn populate_event_output(
        result: &mut ScreenSessionResultHandle,
        output: &mut OwnedOutput,
        name: Option<String>,
        event_type: u32,
        open_url: Option<OwnedOpenUrl>,
        delay_seconds: f32,
        properties: Vec<core::FlowEventProperty>,
    ) -> Result<(), RuntimeFailure> {
        output.open_url = open_url;
        output.name = name.unwrap_or_default().into_bytes();
        output.event_type = event_type;
        output.delay_seconds = delay_seconds;
        output.first_event_property = u32::try_from(result.event_properties.len())
            .map_err(|_| RuntimeFailure::runtime("event property index overflowed"))?;
        output.event_property_count = u32::try_from(properties.len())
            .map_err(|_| RuntimeFailure::runtime("event property count overflowed"))?;
        for property in properties {
            let (value_root_index, trigger_count) = match property.value {
                core::FlowScalarValue::Trigger(count) => (None, Some(count)),
                value => (Some(push_scalar(result, value)?), None),
            };
            result.event_properties.push(OwnedEventProperty {
                value_root_index,
                trigger_count,
                name: property.name.unwrap_or_default().into_bytes(),
            });
        }
        Ok(())
    }

    fn push_scalar(
        result: &mut ScreenSessionResultHandle,
        value: core::FlowScalarValue,
    ) -> Result<u32, RuntimeFailure> {
        let index = u32::try_from(result.value_arena.nodes.len())
            .map_err(|_| RuntimeFailure::runtime("value node index overflowed"))?;
        let (kind, number_value, color_value, bool_value, identity_value, string_value) =
            match value {
                core::FlowScalarValue::Null => {
                    (NUX_SCREEN_VALUE_KIND_NULL, 0.0, 0, false, 0, Vec::new())
                }
                core::FlowScalarValue::String(value) => (
                    NUX_SCREEN_VALUE_KIND_STRING,
                    0.0,
                    0,
                    false,
                    0,
                    value.into_bytes(),
                ),
                core::FlowScalarValue::Number(value) => (
                    NUX_SCREEN_VALUE_KIND_NUMBER,
                    f64::from(value),
                    0,
                    false,
                    0,
                    Vec::new(),
                ),
                core::FlowScalarValue::Bool(value) => {
                    (NUX_SCREEN_VALUE_KIND_BOOL, 0.0, 0, value, 0, Vec::new())
                }
                core::FlowScalarValue::Enum(value) => {
                    (NUX_SCREEN_VALUE_KIND_ENUM, 0.0, 0, false, value, Vec::new())
                }
                core::FlowScalarValue::ListIndex(value) => (
                    NUX_SCREEN_VALUE_KIND_LIST_INDEX,
                    0.0,
                    0,
                    false,
                    value,
                    Vec::new(),
                ),
                core::FlowScalarValue::Color(value) => (
                    NUX_SCREEN_VALUE_KIND_COLOR,
                    0.0,
                    value,
                    false,
                    0,
                    Vec::new(),
                ),
                core::FlowScalarValue::Image(value) => (
                    NUX_SCREEN_VALUE_KIND_IMAGE,
                    0.0,
                    0,
                    false,
                    value,
                    Vec::new(),
                ),
                core::FlowScalarValue::Trigger(_) => {
                    return Err(RuntimeFailure::runtime(
                        "trigger counts are valid only in event properties",
                    ));
                }
            };
        result.value_arena.nodes.push(OwnedValueNode {
            kind,
            number_value,
            color_value,
            bool_value,
            first_edge: 0,
            edge_count: 0,
            instance_id: None,
            identity_value,
            string_value,
            schema_id: Vec::new(),
        });
        Ok(index)
    }

    fn push_state_change_value(
        result: &mut ScreenSessionResultHandle,
        value: core::FlowStateChangeValue,
    ) -> Result<u32, RuntimeFailure> {
        match value {
            core::FlowStateChangeValue::Scalar(value) => push_scalar(result, value),
            core::FlowStateChangeValue::ViewModelReference {
                instance_id,
                schema_name,
            } => {
                let index = u32::try_from(result.value_arena.nodes.len())
                    .map_err(|_| RuntimeFailure::runtime("value node index overflowed"))?;
                result.value_arena.nodes.push(OwnedValueNode {
                    kind: NUX_SCREEN_VALUE_KIND_VIEW_MODEL,
                    number_value: 0.0,
                    color_value: 0,
                    bool_value: false,
                    first_edge: 0,
                    edge_count: 0,
                    instance_id: Some(instance_id.get()),
                    identity_value: 0,
                    string_value: Vec::new(),
                    schema_id: schema_name.into_bytes(),
                });
                Ok(index)
            }
        }
    }

    fn push_host_value(
        result: &mut ScreenSessionResultHandle,
        value: core::FlowHostValue,
    ) -> Result<u32, RuntimeFailure> {
        let (kind, number_value, bool_value, string_value, child_edges) = match value {
            core::FlowHostValue::Bool(value) => (
                NUX_SCREEN_VALUE_KIND_BOOL,
                0.0,
                value,
                Vec::new(),
                Vec::new(),
            ),
            core::FlowHostValue::Number(value) => (
                NUX_SCREEN_VALUE_KIND_NUMBER,
                value,
                false,
                Vec::new(),
                Vec::new(),
            ),
            core::FlowHostValue::String(value) => (
                NUX_SCREEN_VALUE_KIND_STRING,
                0.0,
                false,
                value.into_bytes(),
                Vec::new(),
            ),
            core::FlowHostValue::List(values) => {
                let mut edges = Vec::with_capacity(values.len());
                for value in values {
                    edges.push(OwnedValueEdge {
                        node_index: push_host_value(result, value)?,
                        key: Vec::new(),
                    });
                }
                (NUX_SCREEN_VALUE_KIND_LIST, 0.0, false, Vec::new(), edges)
            }
            core::FlowHostValue::Object(values) => {
                let mut edges = Vec::with_capacity(values.len());
                for (key, value) in values {
                    edges.push(OwnedValueEdge {
                        node_index: push_host_value(result, value)?,
                        key: key.into_bytes(),
                    });
                }
                (NUX_SCREEN_VALUE_KIND_OBJECT, 0.0, false, Vec::new(), edges)
            }
        };
        let first_edge = u32::try_from(result.value_arena.edges.len())
            .map_err(|_| RuntimeFailure::runtime("host value edge index overflowed"))?;
        let edge_count = u32::try_from(child_edges.len())
            .map_err(|_| RuntimeFailure::runtime("host value edge count overflowed"))?;
        result.value_arena.edges.extend(child_edges);
        let index = u32::try_from(result.value_arena.nodes.len())
            .map_err(|_| RuntimeFailure::runtime("host value node index overflowed"))?;
        result.value_arena.nodes.push(OwnedValueNode {
            kind,
            number_value,
            color_value: 0,
            bool_value,
            first_edge: if edge_count == 0 { 0 } else { first_edge },
            edge_count,
            instance_id: None,
            identity_value: 0,
            string_value,
            schema_id: Vec::new(),
        });
        Ok(index)
    }
}

#[cfg(feature = "apple-product")]
#[unsafe(no_mangle)]
/// Creates one independent screen session using the current typed
/// player-selection and bootstrap-result contract. Creation never performs an
/// observable advance. Authenticated script initialization may return ordered cycle-zero
/// host-work outputs. The returned result owns those outputs, player metadata,
/// bounds, catalog, and bootstrap value views until explicitly freed.
///
/// # Safety
///
/// `context` must be live. Non-null pointers must be properly aligned and valid
/// for this synchronous call. Output pointers must address writable storage.
pub unsafe extern "C" fn nux_screen_session_create_configured(
    context: *const NuxExperienceContext,
    descriptor: *const NuxScreenConfiguredSessionDescriptor,
    out_session: *mut *mut NuxScreenSession,
    out_result: *mut *mut NuxScreenSessionResult,
) -> NuxStatus {
    ffi_guard_with_session_result(
        out_result,
        || {},
        || {
            reset_out_handle(out_session);
            reset_session_result(out_result);
            if context.is_null()
                || descriptor.is_null()
                || out_session.is_null()
                || out_result.is_null()
            {
                return write_session_failure(
                    out_result,
                    NuxStatus::NullArgument,
                    "configured session creation requires context, descriptor, session output, and result output",
                );
            }
            let descriptor = match unsafe { copy_configured_session_descriptor(descriptor) } {
                Ok(descriptor) => descriptor,
                Err(status) => {
                    return write_session_failure(
                        out_result,
                        status,
                        "configured session descriptor is malformed or has the wrong exact size",
                    );
                }
            };
            let context = unsafe { &*context.cast::<ExperienceRuntimeContextHandle>() };
            match configured_session_seam::create(context, descriptor) {
                Ok((session, result)) => {
                    let result_status = replace_session_result(out_result, result);
                    if result_status == NuxStatus::Ok {
                        unsafe {
                            *out_session = Box::into_raw(session).cast();
                        }
                    }
                    result_status
                }
                Err(failure) => write_session_runtime_failure(out_result, failure),
            }
        },
    )
}

#[cfg(feature = "apple-product")]
#[unsafe(no_mangle)]
/// Performs one fully copied operation on the session's pinned worker.
/// Rust never calls Swift reentrantly; ordered outputs are returned in the owned
/// result. State batches are atomic and pointer batches preserve immediate
/// subcycles inside their returned `cycle` values.
///
/// # Safety
///
/// `session` must be live. The operation and every selected nested array/view
/// must remain readable for this synchronous call. `out_result` must be writable.
pub unsafe extern "C" fn nux_screen_session_perform(
    session: *const NuxScreenSession,
    operation: *const NuxScreenSessionOperation,
    out_result: *mut *mut NuxScreenSessionResult,
) -> NuxStatus {
    ffi_guard_with_session_result(
        out_result,
        || unsafe { poison_session_handle(session) },
        || {
            reset_session_result(out_result);
            if operation.is_null() || out_result.is_null() {
                return write_session_failure(
                    out_result,
                    NuxStatus::NullArgument,
                    "session perform requires an operation and result output",
                );
            }
            let operation = match unsafe { copy_session_operation(operation) } {
                Ok(operation) => operation,
                Err(status) => {
                    return write_session_failure(
                        out_result,
                        status,
                        "session operation is malformed, has the wrong exact size, or exceeds a published bound",
                    );
                }
            };
            if session.is_null() {
                return write_session_failure(
                    out_result,
                    NuxStatus::NullArgument,
                    "session perform requires a live session",
                );
            }
            let (status, result) = configured_session_seam::perform(session, operation);
            let result_status = replace_session_result(out_result, result);
            if result_status == NuxStatus::Ok {
                status
            } else {
                result_status
            }
        },
    )
}

#[unsafe(no_mangle)]
/// Returns a session result's status, or `NULL_ARGUMENT` for null.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_status(
    result: *const NuxScreenSessionResult,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if result.is_null() {
            NuxStatus::NullArgument
        } else {
            unsafe { (*result.cast::<ScreenSessionResultHandle>()).status }
        }
    })
}

#[unsafe(no_mangle)]
/// Returns the exact Apple-surface disposition for this operation.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_surface_disposition(
    result: *const NuxScreenSessionResult,
) -> NuxSurfaceDisposition {
    ffi_guard(NuxSurfaceDisposition::Fatal, || {
        if result.is_null() {
            NuxSurfaceDisposition::Fatal
        } else {
            unsafe { (*result.cast::<ScreenSessionResultHandle>()).surface_disposition }
        }
    })
}

#[unsafe(no_mangle)]
/// Dirty and settled are independent runtime facts; this returns dirty only.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_is_dirty(
    result: *const NuxScreenSessionResult,
) -> bool {
    ffi_guard(false, || {
        !result.is_null() && unsafe { (*result.cast::<ScreenSessionResultHandle>()).is_dirty }
    })
}

#[unsafe(no_mangle)]
/// Dirty and settled are independent runtime facts; this returns settled only.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_is_settled(
    result: *const NuxScreenSessionResult,
) -> bool {
    ffi_guard(false, || {
        !result.is_null() && unsafe { (*result.cast::<ScreenSessionResultHandle>()).is_settled }
    })
}

#[unsafe(no_mangle)]
/// Whether this result carries a canonical catalog snapshot, including a
/// valid present-but-empty snapshot.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_has_catalog(
    result: *const NuxScreenSessionResult,
) -> bool {
    ffi_guard(false, || {
        !result.is_null() && unsafe { (*result.cast::<ScreenSessionResultHandle>()).has_catalog }
    })
}

#[unsafe(no_mangle)]
/// Whether this result carries a player-input snapshot, including a valid
/// present-but-empty snapshot for a static or animation player.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_has_player_inputs(
    result: *const NuxScreenSessionResult,
) -> bool {
    ffi_guard(false, || {
        !result.is_null()
            && unsafe { (*result.cast::<ScreenSessionResultHandle>()).has_player_inputs }
    })
}

#[unsafe(no_mangle)]
/// Whether this result carries a canonical value snapshot, including a valid
/// present-but-empty snapshot. Output payload nodes alone do not set this.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_has_values(
    result: *const NuxScreenSessionResult,
) -> bool {
    ffi_guard(false, || {
        !result.is_null() && unsafe { (*result.cast::<ScreenSessionResultHandle>()).has_values }
    })
}

#[unsafe(no_mangle)]
/// Writes the optional nonnegative app-clock delay until runtime work is due.
/// Returns `NOT_FOUND` when no wake is scheduled.
///
/// # Safety
///
/// `result` must be live and `out_wake_after_seconds` writable.
pub unsafe extern "C" fn nux_screen_session_result_wake_after_seconds(
    result: *const NuxScreenSessionResult,
    out_wake_after_seconds: *mut f64,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_wake_after_seconds.is_null() {
            return NuxStatus::NullArgument;
        }
        unsafe {
            *out_wake_after_seconds = 0.0;
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let Some(wake_after) =
            (unsafe { (*result.cast::<ScreenSessionResultHandle>()).wake_after })
        else {
            return NuxStatus::NotFound;
        };
        unsafe {
            *out_wake_after_seconds = wake_after;
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Borrows bootstrap player metadata and exact authored artboard bounds.
/// Returns `NOT_FOUND` for operation results that do not carry bootstrap data.
///
/// # Safety
///
/// `result` must be live. `out_metadata` must be writable with its exact
/// published `struct_size`; returned views expire when `result` is freed.
pub unsafe extern "C" fn nux_screen_session_result_player_metadata(
    result: *const NuxScreenSessionResult,
    out_metadata: *mut NuxScreenPlayerMetadataView,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_metadata.is_null() {
            return NuxStatus::NullArgument;
        }
        if unsafe { read_struct_size(out_metadata) } != size_u32::<NuxScreenPlayerMetadataView>() {
            return NuxStatus::InvalidArgument;
        }
        unsafe {
            ptr::write_bytes(out_metadata, 0, 1);
            (*out_metadata).struct_size = size_u32::<NuxScreenPlayerMetadataView>();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let handle = unsafe { &*result.cast::<ScreenSessionResultHandle>() };
        let Some(metadata) = handle.player_metadata.as_ref() else {
            return NuxStatus::NotFound;
        };
        unsafe {
            *out_metadata = NuxScreenPlayerMetadataView {
                struct_size: size_u32::<NuxScreenPlayerMetadataView>(),
                kind: metadata.kind,
                selection: metadata.selection,
                player_index: metadata.player_index.unwrap_or(u32::MAX),
                artboard_name: borrowed_view(&metadata.artboard_name),
                player_name: borrowed_view(&metadata.player_name),
                min_x: metadata.min_x,
                min_y: metadata.min_y,
                max_x: metadata.max_x,
                max_y: metadata.max_y,
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Returns the number of state-machine inputs returned by a player-input query.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_player_input_count(
    result: *const NuxScreenSessionResult,
) -> u64 {
    ffi_guard(0, || {
        if result.is_null() {
            0
        } else {
            u64::try_from(
                unsafe { &*result.cast::<ScreenSessionResultHandle>() }
                    .player_inputs
                    .len(),
            )
            .unwrap_or(u64::MAX)
        }
    })
}

#[unsafe(no_mangle)]
/// Borrows one state-machine input snapshot by authored order.
///
/// # Safety
///
/// `result` must be live. `out_input` must have the exact published size.
pub unsafe extern "C" fn nux_screen_session_result_player_input_at(
    result: *const NuxScreenSessionResult,
    index: u64,
    out_input: *mut NuxScreenPlayerInputView,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_input.is_null() {
            return NuxStatus::NullArgument;
        }
        if unsafe { read_struct_size(out_input) } != size_u32::<NuxScreenPlayerInputView>() {
            return NuxStatus::InvalidArgument;
        }
        unsafe {
            ptr::write_bytes(out_input, 0, 1);
            (*out_input).struct_size = size_u32::<NuxScreenPlayerInputView>();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let Ok(index) = usize::try_from(index) else {
            return NuxStatus::NotFound;
        };
        let handle = unsafe { &*result.cast::<ScreenSessionResultHandle>() };
        let Some(input) = handle.player_inputs.get(index) else {
            return NuxStatus::NotFound;
        };
        unsafe {
            *out_input = NuxScreenPlayerInputView {
                struct_size: size_u32::<NuxScreenPlayerInputView>(),
                kind: input.kind,
                value_root_index: input.value_root_index,
                name: borrowed_view(&input.name),
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Returns the number of view-model schemas in this result.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_schema_count(
    result: *const NuxScreenSessionResult,
) -> u64 {
    ffi_guard(0, || {
        if result.is_null() {
            0
        } else {
            u64::try_from(
                unsafe { &*result.cast::<ScreenSessionResultHandle>() }
                    .schemas
                    .len(),
            )
            .unwrap_or(u64::MAX)
        }
    })
}

#[unsafe(no_mangle)]
/// Borrows one schema by stable result order.
///
/// # Safety
///
/// `result` must be live. `out_schema` must have the exact published size.
pub unsafe extern "C" fn nux_screen_session_result_schema_at(
    result: *const NuxScreenSessionResult,
    index: u64,
    out_schema: *mut NuxScreenSchemaView,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_schema.is_null() {
            return NuxStatus::NullArgument;
        }
        if unsafe { read_struct_size(out_schema) } != size_u32::<NuxScreenSchemaView>() {
            return NuxStatus::InvalidArgument;
        }
        unsafe {
            ptr::write_bytes(out_schema, 0, 1);
            (*out_schema).struct_size = size_u32::<NuxScreenSchemaView>();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let Ok(index) = usize::try_from(index) else {
            return NuxStatus::NotFound;
        };
        let handle = unsafe { &*result.cast::<ScreenSessionResultHandle>() };
        let Some(schema) = handle.schemas.get(index) else {
            return NuxStatus::NotFound;
        };
        unsafe {
            *out_schema = NuxScreenSchemaView {
                struct_size: size_u32::<NuxScreenSchemaView>(),
                first_property: schema.first_property,
                property_count: schema.property_count,
                schema_id: borrowed_view(&schema.schema_id),
                name: borrowed_view(&schema.name),
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Returns the number of flattened schema properties in this result.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_schema_property_count(
    result: *const NuxScreenSessionResult,
) -> u64 {
    ffi_guard(0, || {
        if result.is_null() {
            0
        } else {
            u64::try_from(
                unsafe { &*result.cast::<ScreenSessionResultHandle>() }
                    .schema_properties
                    .len(),
            )
            .unwrap_or(u64::MAX)
        }
    })
}

#[unsafe(no_mangle)]
/// Borrows one flattened schema property by stable result order.
///
/// # Safety
///
/// `result` must be live. `out_property` must have the exact published size.
pub unsafe extern "C" fn nux_screen_session_result_schema_property_at(
    result: *const NuxScreenSessionResult,
    index: u64,
    out_property: *mut NuxScreenSchemaPropertyView,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_property.is_null() {
            return NuxStatus::NullArgument;
        }
        if unsafe { read_struct_size(out_property) } != size_u32::<NuxScreenSchemaPropertyView>() {
            return NuxStatus::InvalidArgument;
        }
        unsafe {
            ptr::write_bytes(out_property, 0, 1);
            (*out_property).struct_size = size_u32::<NuxScreenSchemaPropertyView>();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let Ok(index) = usize::try_from(index) else {
            return NuxStatus::NotFound;
        };
        let handle = unsafe { &*result.cast::<ScreenSessionResultHandle>() };
        let Some(property) = handle.schema_properties.get(index) else {
            return NuxStatus::NotFound;
        };
        unsafe {
            *out_property = NuxScreenSchemaPropertyView {
                struct_size: size_u32::<NuxScreenSchemaPropertyView>(),
                kind: property.kind,
                schema_id: borrowed_view(&property.schema_id),
                property_id: borrowed_view(&property.property_id),
                name: borrowed_view(&property.name),
                referenced_schema_id: borrowed_view(&property.referenced_schema_id),
                first_enum_label: property.first_enum_label,
                enum_label_count: property.enum_label_count,
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Returns the number of flattened authored enum labels in this result.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_enum_label_count(
    result: *const NuxScreenSessionResult,
) -> u64 {
    ffi_guard(0, || {
        if result.is_null() {
            0
        } else {
            u64::try_from(
                unsafe { &*result.cast::<ScreenSessionResultHandle>() }
                    .enum_labels
                    .len(),
            )
            .unwrap_or(u64::MAX)
        }
    })
}

#[unsafe(no_mangle)]
/// Borrows one flattened authored enum label by stable result order.
///
/// # Safety
///
/// `result` must be live. `out_label` must have the exact published size.
pub unsafe extern "C" fn nux_screen_session_result_enum_label_at(
    result: *const NuxScreenSessionResult,
    index: u64,
    out_label: *mut NuxScreenEnumLabelView,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_label.is_null() {
            return NuxStatus::NullArgument;
        }
        if unsafe { read_struct_size(out_label) } != size_u32::<NuxScreenEnumLabelView>() {
            return NuxStatus::InvalidArgument;
        }
        unsafe {
            ptr::write_bytes(out_label, 0, 1);
            (*out_label).struct_size = size_u32::<NuxScreenEnumLabelView>();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let Ok(index) = usize::try_from(index) else {
            return NuxStatus::NotFound;
        };
        let handle = unsafe { &*result.cast::<ScreenSessionResultHandle>() };
        let Some(label) = handle.enum_labels.get(index) else {
            return NuxStatus::NotFound;
        };
        unsafe {
            *out_label = NuxScreenEnumLabelView {
                struct_size: size_u32::<NuxScreenEnumLabelView>(),
                value: label.value,
                label: borrowed_view(&label.label),
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Returns the number of authored immutable instance templates in this result.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_instance_template_count(
    result: *const NuxScreenSessionResult,
) -> u64 {
    ffi_guard(0, || {
        if result.is_null() {
            0
        } else {
            u64::try_from(
                unsafe { &*result.cast::<ScreenSessionResultHandle>() }
                    .instance_templates
                    .len(),
            )
            .unwrap_or(u64::MAX)
        }
    })
}

#[unsafe(no_mangle)]
/// Borrows one authored immutable instance template by result order.
///
/// # Safety
///
/// `result` must be live. `out_template` must have the exact published size.
pub unsafe extern "C" fn nux_screen_session_result_instance_template_at(
    result: *const NuxScreenSessionResult,
    index: u64,
    out_template: *mut NuxScreenInstanceTemplateView,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_template.is_null() {
            return NuxStatus::NullArgument;
        }
        if unsafe { read_struct_size(out_template) } != size_u32::<NuxScreenInstanceTemplateView>()
        {
            return NuxStatus::InvalidArgument;
        }
        unsafe {
            ptr::write_bytes(out_template, 0, 1);
            (*out_template).struct_size = size_u32::<NuxScreenInstanceTemplateView>();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let Ok(index) = usize::try_from(index) else {
            return NuxStatus::NotFound;
        };
        let handle = unsafe { &*result.cast::<ScreenSessionResultHandle>() };
        let Some(template) = handle.instance_templates.get(index) else {
            return NuxStatus::NotFound;
        };
        unsafe {
            *out_template = NuxScreenInstanceTemplateView {
                struct_size: size_u32::<NuxScreenInstanceTemplateView>(),
                authored_index: template.authored_index,
                schema_id: borrowed_view(&template.schema_id),
                authored_name: borrowed_view(&template.authored_name),
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Returns the number of stable external instances in this result.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_instance_count(
    result: *const NuxScreenSessionResult,
) -> u64 {
    ffi_guard(0, || {
        if result.is_null() {
            0
        } else {
            u64::try_from(
                unsafe { &*result.cast::<ScreenSessionResultHandle>() }
                    .instances
                    .len(),
            )
            .unwrap_or(u64::MAX)
        }
    })
}

#[unsafe(no_mangle)]
/// Borrows one stable external instance by result order.
///
/// # Safety
///
/// `result` must be live. `out_instance` must have the exact published size.
pub unsafe extern "C" fn nux_screen_session_result_instance_at(
    result: *const NuxScreenSessionResult,
    index: u64,
    out_instance: *mut NuxScreenInstanceView,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_instance.is_null() {
            return NuxStatus::NullArgument;
        }
        if unsafe { read_struct_size(out_instance) } != size_u32::<NuxScreenInstanceView>() {
            return NuxStatus::InvalidArgument;
        }
        unsafe {
            ptr::write_bytes(out_instance, 0, 1);
            (*out_instance).struct_size = size_u32::<NuxScreenInstanceView>();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let Ok(index) = usize::try_from(index) else {
            return NuxStatus::NotFound;
        };
        let handle = unsafe { &*result.cast::<ScreenSessionResultHandle>() };
        let Some(instance) = handle.instances.get(index) else {
            return NuxStatus::NotFound;
        };
        unsafe {
            *out_instance = NuxScreenInstanceView {
                struct_size: size_u32::<NuxScreenInstanceView>(),
                value_root_index: instance.value_root_index.unwrap_or(NO_VALUE_ROOT),
                is_root: u32::from(instance.is_root),
                instance_id: instance.instance_id,
                schema_id: borrowed_view(&instance.schema_id),
                name: borrowed_view(&instance.name),
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Returns the number of instance-to-value roots in this result.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_value_root_count(
    result: *const NuxScreenSessionResult,
) -> u64 {
    ffi_guard(0, || {
        if result.is_null() {
            0
        } else {
            u64::try_from(
                unsafe { &*result.cast::<ScreenSessionResultHandle>() }
                    .value_roots
                    .len(),
            )
            .unwrap_or(u64::MAX)
        }
    })
}

#[unsafe(no_mangle)]
/// Borrows one instance-to-value root by result order.
///
/// # Safety
///
/// `result` must be live. `out_root` must have the exact published size.
pub unsafe extern "C" fn nux_screen_session_result_value_root_at(
    result: *const NuxScreenSessionResult,
    index: u64,
    out_root: *mut NuxScreenValueRootView,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_root.is_null() {
            return NuxStatus::NullArgument;
        }
        if unsafe { read_struct_size(out_root) } != size_u32::<NuxScreenValueRootView>() {
            return NuxStatus::InvalidArgument;
        }
        unsafe {
            ptr::write_bytes(out_root, 0, 1);
            (*out_root).struct_size = size_u32::<NuxScreenValueRootView>();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let Ok(index) = usize::try_from(index) else {
            return NuxStatus::NotFound;
        };
        let handle = unsafe { &*result.cast::<ScreenSessionResultHandle>() };
        let Some(root) = handle.value_roots.get(index) else {
            return NuxStatus::NotFound;
        };
        unsafe {
            *out_root = NuxScreenValueRootView {
                struct_size: size_u32::<NuxScreenValueRootView>(),
                value_root_index: root.value_root_index,
                instance_id: root.instance_id,
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Returns the number of local-to-stable instance mappings created by a batch.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_created_instance_count(
    result: *const NuxScreenSessionResult,
) -> u64 {
    ffi_guard(0, || {
        if result.is_null() {
            0
        } else {
            u64::try_from(
                unsafe { &*result.cast::<ScreenSessionResultHandle>() }
                    .created_instances
                    .len(),
            )
            .unwrap_or(u64::MAX)
        }
    })
}

#[unsafe(no_mangle)]
/// Borrows one local-to-stable instance mapping by result order.
///
/// # Safety
///
/// `result` must be live. `out_created` must have the exact published size.
pub unsafe extern "C" fn nux_screen_session_result_created_instance_at(
    result: *const NuxScreenSessionResult,
    index: u64,
    out_created: *mut NuxScreenCreatedInstanceView,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_created.is_null() {
            return NuxStatus::NullArgument;
        }
        if unsafe { read_struct_size(out_created) } != size_u32::<NuxScreenCreatedInstanceView>() {
            return NuxStatus::InvalidArgument;
        }
        unsafe {
            ptr::write_bytes(out_created, 0, 1);
            (*out_created).struct_size = size_u32::<NuxScreenCreatedInstanceView>();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let Ok(index) = usize::try_from(index) else {
            return NuxStatus::NotFound;
        };
        let handle = unsafe { &*result.cast::<ScreenSessionResultHandle>() };
        let Some(created) = handle.created_instances.get(index) else {
            return NuxStatus::NotFound;
        };
        unsafe {
            *out_created = NuxScreenCreatedInstanceView {
                struct_size: size_u32::<NuxScreenCreatedInstanceView>(),
                local_id: created.local_id,
                instance_id: created.instance_id,
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Returns the number of nodes in the result-owned value arena.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_value_node_count(
    result: *const NuxScreenSessionResult,
) -> u64 {
    ffi_guard(0, || {
        if result.is_null() {
            0
        } else {
            u64::try_from(
                unsafe { &*result.cast::<ScreenSessionResultHandle>() }
                    .value_arena
                    .nodes
                    .len(),
            )
            .unwrap_or(u64::MAX)
        }
    })
}

#[unsafe(no_mangle)]
/// Borrows one result-owned value node by arena index.
///
/// # Safety
///
/// `result` must be live. `out_node` must have the exact published size.
pub unsafe extern "C" fn nux_screen_session_result_value_node_at(
    result: *const NuxScreenSessionResult,
    index: u64,
    out_node: *mut NuxScreenValueNode,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_node.is_null() {
            return NuxStatus::NullArgument;
        }
        if unsafe { read_struct_size(out_node) } != size_u32::<NuxScreenValueNode>() {
            return NuxStatus::InvalidArgument;
        }
        unsafe {
            ptr::write_bytes(out_node, 0, 1);
            (*out_node).struct_size = size_u32::<NuxScreenValueNode>();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let Ok(index) = usize::try_from(index) else {
            return NuxStatus::NotFound;
        };
        let handle = unsafe { &*result.cast::<ScreenSessionResultHandle>() };
        let Some(node) = handle.value_arena.nodes.get(index) else {
            return NuxStatus::NotFound;
        };
        unsafe {
            *out_node = NuxScreenValueNode {
                struct_size: size_u32::<NuxScreenValueNode>(),
                kind: node.kind,
                number_value: node.number_value,
                color_value: node.color_value,
                bool_value: u32::from(node.bool_value),
                first_edge: node.first_edge,
                edge_count: node.edge_count,
                has_instance_id: u32::from(node.instance_id.is_some()),
                instance_id: node.instance_id.unwrap_or(0),
                identity_value: node.identity_value,
                string_value: borrowed_view(&node.string_value),
                schema_id: borrowed_view(&node.schema_id),
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Returns the number of edges in the result-owned value arena.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_value_edge_count(
    result: *const NuxScreenSessionResult,
) -> u64 {
    ffi_guard(0, || {
        if result.is_null() {
            0
        } else {
            u64::try_from(
                unsafe { &*result.cast::<ScreenSessionResultHandle>() }
                    .value_arena
                    .edges
                    .len(),
            )
            .unwrap_or(u64::MAX)
        }
    })
}

#[unsafe(no_mangle)]
/// Borrows one result-owned value edge by arena index.
///
/// # Safety
///
/// `result` must be live. `out_edge` must have the exact published size.
pub unsafe extern "C" fn nux_screen_session_result_value_edge_at(
    result: *const NuxScreenSessionResult,
    index: u64,
    out_edge: *mut NuxScreenValueEdge,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_edge.is_null() {
            return NuxStatus::NullArgument;
        }
        if unsafe { read_struct_size(out_edge) } != size_u32::<NuxScreenValueEdge>() {
            return NuxStatus::InvalidArgument;
        }
        unsafe {
            ptr::write_bytes(out_edge, 0, 1);
            (*out_edge).struct_size = size_u32::<NuxScreenValueEdge>();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let Ok(index) = usize::try_from(index) else {
            return NuxStatus::NotFound;
        };
        let handle = unsafe { &*result.cast::<ScreenSessionResultHandle>() };
        let Some(edge) = handle.value_arena.edges.get(index) else {
            return NuxStatus::NotFound;
        };
        unsafe {
            *out_edge = NuxScreenValueEdge {
                struct_size: size_u32::<NuxScreenValueEdge>(),
                node_index: edge.node_index,
                key: borrowed_view(&edge.key),
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Returns the number of exact-order outputs in this result.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_output_count(
    result: *const NuxScreenSessionResult,
) -> u64 {
    ffi_guard(0, || {
        if result.is_null() {
            0
        } else {
            u64::try_from(
                unsafe { &*result.cast::<ScreenSessionResultHandle>() }
                    .outputs
                    .len(),
            )
            .unwrap_or(u64::MAX)
        }
    })
}

#[unsafe(no_mangle)]
/// Borrows one exact-order output by result order.
///
/// # Safety
///
/// `result` must be live. `out_output` must have the exact published size.
pub unsafe extern "C" fn nux_screen_session_result_output_at(
    result: *const NuxScreenSessionResult,
    index: u64,
    out_output: *mut NuxScreenOutputView,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_output.is_null() {
            return NuxStatus::NullArgument;
        }
        if unsafe { read_struct_size(out_output) } != size_u32::<NuxScreenOutputView>() {
            return NuxStatus::InvalidArgument;
        }
        unsafe {
            ptr::write_bytes(out_output, 0, 1);
            (*out_output).struct_size = size_u32::<NuxScreenOutputView>();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let Ok(index) = usize::try_from(index) else {
            return NuxStatus::NotFound;
        };
        let handle = unsafe { &*result.cast::<ScreenSessionResultHandle>() };
        let Some(output) = handle.outputs.get(index) else {
            return NuxStatus::NotFound;
        };
        let (has_open_url, open_url, open_url_target) = output.open_url.as_ref().map_or(
            (0, NuxByteView::default(), NuxByteView::default()),
            |value| (1, borrowed_view(&value.url), borrowed_view(&value.target)),
        );
        unsafe {
            *out_output = NuxScreenOutputView {
                struct_size: size_u32::<NuxScreenOutputView>(),
                phase: output.phase,
                kind: output.kind,
                payload_root_index: output.payload_root_index.unwrap_or(NO_VALUE_ROOT),
                has_origin_mutation_id: u32::from(output.origin_mutation_id.is_some()),
                has_instance_id: u32::from(output.instance_id.is_some()),
                sequence: output.sequence,
                cycle: output.cycle,
                origin_mutation_id: output.origin_mutation_id.unwrap_or(0),
                instance_id: output.instance_id.unwrap_or(0),
                event_type: output.event_type,
                first_event_property: output.first_event_property,
                event_property_count: output.event_property_count,
                delay_seconds: output.delay_seconds,
                name: borrowed_view(&output.name),
                path: borrowed_view(&output.path),
                payload: borrowed_view(&output.payload),
                has_open_url,
                open_url,
                open_url_target,
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Returns the number of flattened typed event properties in this result.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_event_property_count(
    result: *const NuxScreenSessionResult,
) -> u64 {
    ffi_guard(0, || {
        if result.is_null() {
            0
        } else {
            u64::try_from(
                unsafe { &*result.cast::<ScreenSessionResultHandle>() }
                    .event_properties
                    .len(),
            )
            .unwrap_or(u64::MAX)
        }
    })
}

#[unsafe(no_mangle)]
/// Borrows one flattened typed event property by result order.
///
/// # Safety
///
/// `result` must be live. `out_property` must have the exact published size.
pub unsafe extern "C" fn nux_screen_session_result_event_property_at(
    result: *const NuxScreenSessionResult,
    index: u64,
    out_property: *mut NuxScreenEventPropertyView,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_property.is_null() {
            return NuxStatus::NullArgument;
        }
        if unsafe { read_struct_size(out_property) } != size_u32::<NuxScreenEventPropertyView>() {
            return NuxStatus::InvalidArgument;
        }
        unsafe {
            ptr::write_bytes(out_property, 0, 1);
            (*out_property).struct_size = size_u32::<NuxScreenEventPropertyView>();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let Ok(index) = usize::try_from(index) else {
            return NuxStatus::NotFound;
        };
        let handle = unsafe { &*result.cast::<ScreenSessionResultHandle>() };
        let Some(property) = handle.event_properties.get(index) else {
            return NuxStatus::NotFound;
        };
        unsafe {
            *out_property = NuxScreenEventPropertyView {
                struct_size: size_u32::<NuxScreenEventPropertyView>(),
                value_root_index: property.value_root_index.unwrap_or(NO_VALUE_ROOT),
                has_trigger_count: u32::from(property.trigger_count.is_some()),
                trigger_count: property.trigger_count.unwrap_or(0),
                name: borrowed_view(&property.name),
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Returns the number of phase-ordered diagnostics in this result.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_screen_session_result_diagnostic_count(
    result: *const NuxScreenSessionResult,
) -> u64 {
    ffi_guard(0, || {
        if result.is_null() {
            0
        } else {
            u64::try_from(
                unsafe { &*result.cast::<ScreenSessionResultHandle>() }
                    .diagnostics
                    .len(),
            )
            .unwrap_or(u64::MAX)
        }
    })
}

#[unsafe(no_mangle)]
/// Borrows one structured diagnostic by result order.
///
/// # Safety
///
/// `result` must be live. `out_diagnostic` must have the exact published
/// diagnostic-view size; returned byte views expire when `result` is freed.
pub unsafe extern "C" fn nux_screen_session_result_diagnostic_at(
    result: *const NuxScreenSessionResult,
    index: u64,
    out_diagnostic: *mut NuxDiagnosticView,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_diagnostic.is_null() {
            return NuxStatus::NullArgument;
        }
        if unsafe { read_struct_size(out_diagnostic) } != size_u32::<NuxDiagnosticView>() {
            return NuxStatus::InvalidArgument;
        }
        unsafe {
            *out_diagnostic = NuxDiagnosticView::default();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let Ok(index) = usize::try_from(index) else {
            return NuxStatus::NotFound;
        };
        let handle = unsafe { &*result.cast::<ScreenSessionResultHandle>() };
        let Some(diagnostic) = handle.diagnostics.get(index) else {
            return NuxStatus::NotFound;
        };
        unsafe {
            *out_diagnostic = NuxDiagnosticView {
                struct_size: size_u32::<NuxDiagnosticView>(),
                severity: diagnostic.severity,
                code: borrowed_view(&diagnostic.code),
                message: borrowed_view(&diagnostic.message),
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Releases one session result. Null is a no-op.
///
/// # Safety
///
/// A non-null pointer must be an owned result returned by this library and must
/// not have been freed before. No borrowed view may be used after this call.
pub unsafe extern "C" fn nux_screen_session_result_free(result: *mut NuxScreenSessionResult) {
    ffi_guard((), || {
        if !result.is_null() {
            unsafe {
                drop(Box::from_raw(result.cast::<ScreenSessionResultHandle>()));
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(feature = "apple-product")]
    use nuxie::flow_session as core;
    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    use objc2::rc::{Retained, autoreleasepool};
    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    use objc2::runtime::ProtocolObject;
    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    use objc2_core_foundation::CGSize;
    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    use objc2_metal::{MTLDevice, MTLPixelFormat};
    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    use objc2_quartz_core::CAMetalLayer;
    #[cfg(feature = "apple-product")]
    use std::collections::BTreeMap;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn bytes(value: &[u8]) -> NuxByteView {
        NuxByteView {
            data: value.as_ptr(),
            len: value.len() as u64,
        }
    }

    #[cfg(feature = "apple-product")]
    unsafe fn session_result_message(result: *const NuxScreenSessionResult) -> String {
        if result.is_null() {
            return "session operation returned no result".to_owned();
        }
        let handle = unsafe { &*result.cast::<ScreenSessionResultHandle>() };
        handle
            .diagnostics
            .first()
            .map(|diagnostic| String::from_utf8_lossy(&diagnostic.message).into_owned())
            .unwrap_or_else(|| "session operation returned no diagnostic".to_owned())
    }

    #[cfg(feature = "apple-product")]
    fn flow_fixture(name: &str) -> Vec<u8> {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .join("fixtures/flow")
            .join(name);
        std::fs::read(&path)
            .unwrap_or_else(|error| panic!("read flow fixture {}: {error}", path.display()))
    }

    fn configured_descriptor() -> NuxScreenConfiguredSessionDescriptor {
        NuxScreenConfiguredSessionDescriptor {
            struct_size: size_u32::<NuxScreenConfiguredSessionDescriptor>(),
            player_kind: NUX_SCREEN_PLAYER_SELECTOR_KIND_DEFAULT,
            artboard_name: NuxByteView::default(),
            player_name: NuxByteView::default(),
        }
    }

    fn operation(kind: NuxScreenSessionOperationKind) -> NuxScreenSessionOperation {
        NuxScreenSessionOperation {
            struct_size: size_u32::<NuxScreenSessionOperation>(),
            kind,
            state_batch: ptr::null(),
            pointer_batch: ptr::null(),
            advance: ptr::null(),
            query_batch: ptr::null(),
            text_run_batch: ptr::null(),
        }
    }

    fn null_node(kind: NuxScreenValueKind) -> NuxScreenValueNode {
        NuxScreenValueNode {
            struct_size: size_u32::<NuxScreenValueNode>(),
            kind,
            number_value: 0.0,
            color_value: 0,
            bool_value: 0,
            first_edge: 0,
            edge_count: 0,
            has_instance_id: 0,
            instance_id: 0,
            identity_value: 0,
            string_value: NuxByteView::default(),
            schema_id: NuxByteView::default(),
        }
    }

    // Compiled with workspace-pinned `luaur-compiler` 0.1.8 after
    // `luaur_common::set_all_flags(true)`, by passing this exact source to
    // `luau_compile` with default options. Exact source follows, including its
    // leading and trailing blank lines (the unsigned envelope byte is added below):
    //
    // local nuxie = require("nuxie")
    //
    // nuxie.trigger("fixture_loaded", {
    //     authenticated = true,
    //     nested = { "apple", 14 },
    // })
    //
    // return function(_context)
    //     return {
    //         init = function(_self)
    //             nuxie.response.set("welcome", {
    //                 title = "Hello from Luau",
    //                 enabled = true,
    //                 count = 14,
    //             })
    //             return true
    //         end,
    //         advance = function(_self, seconds)
    //             if seconds >= 1 then
    //                 for command = 1, 257 do
    //                     nuxie.trigger("overflow_" .. command)
    //                 end
    //             else
    //                 nuxie.trigger("sibling_ok", { delta = seconds })
    //             end
    //             return false
    //         end,
    //     }
    // end
    //
    #[cfg(feature = "apple-product")]
    const SCRIPTED_APPLE_SEAM_BYTECODE: &[u8] = &[
        11, 3, 19, 8, 114, 101, 115, 112, 111, 110, 115, 101, 3, 115, 101, 116, 7, 119, 101, 108,
        99, 111, 109, 101, 5, 116, 105, 116, 108, 101, 15, 72, 101, 108, 108, 111, 32, 102, 114,
        111, 109, 32, 76, 117, 97, 117, 7, 101, 110, 97, 98, 108, 101, 100, 5, 99, 111, 117, 110,
        116, 4, 105, 110, 105, 116, 7, 116, 114, 105, 103, 103, 101, 114, 9, 111, 118, 101, 114,
        102, 108, 111, 119, 95, 10, 115, 105, 98, 108, 105, 110, 103, 95, 111, 107, 5, 100, 101,
        108, 116, 97, 7, 97, 100, 118, 97, 110, 99, 101, 7, 114, 101, 113, 117, 105, 114, 101, 5,
        110, 117, 120, 105, 101, 14, 102, 105, 120, 116, 117, 114, 101, 95, 108, 111, 97, 100, 101,
        100, 13, 97, 117, 116, 104, 101, 110, 116, 105, 99, 97, 116, 101, 100, 6, 110, 101, 115,
        116, 101, 100, 5, 97, 112, 112, 108, 101, 0, 4, 4, 1, 1, 0, 0, 0, 11, 9, 1, 0, 0, 15, 1, 1,
        87, 0, 0, 0, 0, 15, 1, 1, 83, 1, 0, 0, 0, 5, 2, 2, 0, 54, 3, 9, 0, 87, 1, 3, 1, 0, 0, 0, 0,
        3, 1, 1, 0, 22, 1, 2, 0, 10, 3, 1, 3, 2, 3, 3, 3, 4, 3, 5, 3, 6, 1, 1, 3, 7, 2, 0, 0, 0, 0,
        0, 0, 44, 64, 8, 3, 3, 4, 0, 0, 0, 5, 6, 0, 0, 0, 7, 8, 0, 0, 0, 0, 11, 8, 1, 24, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 5, 0, 12, 0, 0, 0, 0, 1, 0, 7, 9, 2, 1, 0, 0, 0, 28, 4, 2, 1, 0, 31, 2,
        15, 0, 1, 0, 0, 0, 4, 4, 1, 0, 4, 2, 1, 1, 4, 3, 1, 0, 56, 2, 19, 0, 9, 5, 0, 0, 15, 5, 5,
        212, 0, 0, 0, 0, 5, 7, 1, 0, 6, 8, 4, 0, 49, 6, 7, 8, 87, 5, 2, 1, 0, 0, 0, 0, 57, 2, 247,
        255, 23, 0, 9, 0, 9, 2, 0, 0, 15, 2, 2, 212, 0, 0, 0, 0, 5, 3, 2, 0, 54, 4, 4, 0, 16, 1, 4,
        214, 3, 0, 0, 0, 87, 2, 3, 1, 1, 0, 0, 0, 3, 2, 0, 0, 22, 2, 2, 0, 5, 3, 9, 3, 10, 3, 11,
        3, 12, 5, 1, 3, 0, 19, 13, 1, 24, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 255, 0, 4,
        0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 20, 0, 0, 0, 0, 2, 0, 13, 0, 24, 3, 1, 1, 0, 0, 0, 10, 54, 1,
        2, 0, 64, 2, 3, 0, 70, 2, 0, 0, 16, 2, 1, 19, 0, 0, 0, 0, 64, 2, 4, 0, 70, 2, 0, 0, 16, 2,
        1, 210, 1, 0, 0, 0, 22, 1, 2, 0, 5, 3, 8, 3, 13, 5, 2, 0, 1, 6, 0, 6, 1, 2, 0, 1, 9, 0, 1,
        24, 0, 1, 0, 0, 0, 8, 0, 0, 0, 0, 10, 0, 0, 0, 0, 0, 7, 0, 0, 1, 2, 0, 21, 65, 0, 0, 0, 12,
        0, 1, 0, 0, 0, 0, 64, 5, 1, 2, 0, 21, 0, 2, 2, 15, 1, 0, 212, 3, 0, 0, 0, 5, 2, 4, 0, 54,
        3, 8, 0, 53, 4, 0, 0, 2, 0, 0, 0, 5, 5, 9, 0, 4, 6, 14, 0, 55, 4, 5, 3, 1, 0, 0, 0, 16, 4,
        3, 90, 7, 0, 0, 0, 21, 1, 3, 1, 64, 1, 10, 0, 70, 0, 0, 0, 22, 1, 2, 0, 11, 3, 14, 4, 0, 0,
        0, 64, 3, 15, 3, 9, 3, 16, 3, 17, 1, 1, 3, 18, 8, 2, 5, 6, 0, 0, 0, 7, 255, 255, 255, 255,
        3, 19, 6, 2, 1, 2, 1, 0, 1, 24, 0, 1, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 254, 5,
        0, 0, 1, 0, 0, 0, 0, 0, 3,
    ];

    #[cfg(feature = "apple-product")]
    fn scripted_fixture_push_var_uint(output: &mut Vec<u8>, mut value: u64) {
        loop {
            let mut byte = (value & 0x7f) as u8;
            value >>= 7;
            if value != 0 {
                byte |= 0x80;
            }
            output.push(byte);
            if value == 0 {
                break;
            }
        }
    }

    #[cfg(feature = "apple-product")]
    fn scripted_fixture_property_key(type_name: &str, property_name: &str) -> u16 {
        let definition = nuxie_schema::definition_by_name(type_name).expect("fixture type exists");
        definition
            .properties
            .iter()
            .chain(definition.ancestors.iter().flat_map(|ancestor| {
                nuxie_schema::definition_by_name(ancestor)
                    .expect("fixture ancestor exists")
                    .properties
                    .iter()
            }))
            .find(|property| property.name == property_name)
            .expect("fixture property exists")
            .key
            .int
    }

    #[cfg(feature = "apple-product")]
    fn scripted_fixture_push_object(
        output: &mut Vec<u8>,
        type_name: &str,
        properties: impl FnOnce(&mut Vec<u8>),
    ) {
        scripted_fixture_push_var_uint(
            output,
            u64::from(
                nuxie_schema::definition_by_name(type_name)
                    .expect("fixture type exists")
                    .type_key
                    .int,
            ),
        );
        properties(output);
        scripted_fixture_push_var_uint(output, 0);
    }

    #[cfg(feature = "apple-product")]
    fn scripted_fixture_push_uint(
        output: &mut Vec<u8>,
        type_name: &str,
        property_name: &str,
        value: u64,
    ) {
        scripted_fixture_push_var_uint(
            output,
            u64::from(scripted_fixture_property_key(type_name, property_name)),
        );
        scripted_fixture_push_var_uint(output, value);
    }

    #[cfg(feature = "apple-product")]
    fn scripted_fixture_push_f32(
        output: &mut Vec<u8>,
        type_name: &str,
        property_name: &str,
        value: f32,
    ) {
        scripted_fixture_push_var_uint(
            output,
            u64::from(scripted_fixture_property_key(type_name, property_name)),
        );
        output.extend_from_slice(&value.to_le_bytes());
    }

    #[cfg(feature = "apple-product")]
    fn scripted_fixture_push_blob(
        output: &mut Vec<u8>,
        type_name: &str,
        property_name: &str,
        value: &[u8],
    ) {
        scripted_fixture_push_var_uint(
            output,
            u64::from(scripted_fixture_property_key(type_name, property_name)),
        );
        scripted_fixture_push_var_uint(output, value.len() as u64);
        output.extend_from_slice(value);
    }

    #[cfg(feature = "apple-product")]
    fn scripted_fixture_push_string(
        output: &mut Vec<u8>,
        type_name: &str,
        property_name: &str,
        value: &str,
    ) {
        scripted_fixture_push_blob(output, type_name, property_name, value.as_bytes());
    }

    #[cfg(feature = "apple-product")]
    fn signed_scripted_apple_seam_artifact() -> Vec<u8> {
        let mut protocol_payload = vec![0];
        protocol_payload.extend_from_slice(SCRIPTED_APPLE_SEAM_BYTECODE);

        let mut output = b"RIVE".to_vec();
        scripted_fixture_push_var_uint(&mut output, 7);
        scripted_fixture_push_var_uint(&mut output, 0);
        scripted_fixture_push_var_uint(&mut output, 9_403);
        scripted_fixture_push_var_uint(&mut output, 0);
        scripted_fixture_push_object(&mut output, "Backboard", |_| {});
        scripted_fixture_push_object(&mut output, "ScriptAsset", |output| {
            scripted_fixture_push_uint(output, "ScriptAsset", "assetId", 0);
            scripted_fixture_push_string(output, "ScriptAsset", "name", "AppleSeamProtocol");
        });
        scripted_fixture_push_object(&mut output, "FileAssetContents", |output| {
            scripted_fixture_push_blob(output, "FileAssetContents", "bytes", &protocol_payload);
        });
        scripted_fixture_push_object(&mut output, "Artboard", |output| {
            scripted_fixture_push_f32(output, "Artboard", "width", 100.0);
            scripted_fixture_push_f32(output, "Artboard", "height", 100.0);
        });
        scripted_fixture_push_object(&mut output, "ScriptedDrawable", |output| {
            scripted_fixture_push_uint(output, "ScriptedDrawable", "parentId", 0);
            scripted_fixture_push_uint(output, "ScriptedDrawable", "scriptAssetId", 0);
        });
        output
    }

    #[cfg(feature = "apple-product")]
    fn text_run_apple_seam_artifact() -> Vec<u8> {
        let mut output = b"RIVE".to_vec();
        scripted_fixture_push_var_uint(&mut output, 7);
        scripted_fixture_push_var_uint(&mut output, 0);
        scripted_fixture_push_var_uint(&mut output, 9_403);
        scripted_fixture_push_var_uint(&mut output, 0);
        scripted_fixture_push_object(&mut output, "Backboard", |_| {});
        scripted_fixture_push_object(&mut output, "Artboard", |output| {
            scripted_fixture_push_string(output, "Artboard", "name", "Root");
            scripted_fixture_push_f32(output, "Artboard", "width", 100.0);
            scripted_fixture_push_f32(output, "Artboard", "height", 100.0);
        });
        scripted_fixture_push_object(&mut output, "Text", |output| {
            scripted_fixture_push_string(output, "Text", "name", "Text");
        });
        scripted_fixture_push_object(&mut output, "TextValueRun", |output| {
            scripted_fixture_push_uint(output, "TextValueRun", "parentId", 1);
            scripted_fixture_push_string(output, "TextValueRun", "name", "headline");
            scripted_fixture_push_string(output, "TextValueRun", "text", "initial");
        });
        output
    }

    #[cfg(feature = "apple-product")]
    fn with_signed_scripted_apple_import_request<R>(
        body: impl FnOnce(&NuxExperienceImportRequest) -> R,
    ) -> R {
        use std::ffi::CString;

        use nux_container::test_support::{TEST_ONLY_DEV_KEY_ID, TEST_ONLY_DEV_KEYPAIR};
        use nux_container::{
            Assets, Entry, Identity, JourneyMember, LuauProducer, NuxPackageManifestV1,
            NuxPackageModel, Producer, SceneFormat, SceneMember, Screen, SignatureSource,
            write_package,
        };

        let scene = signed_scripted_apple_seam_artifact();
        let manifest = NuxPackageManifestV1 {
            version: 1,
            identity: Identity {
                experience_id: "scripted-apple-seam".to_owned(),
                build_id: "build-scripted-apple-seam".to_owned(),
                app_id: "test-app".to_owned(),
                environment: "test".to_owned(),
            },
            producer: Producer {
                compiler_commit: "test".to_owned(),
                compiler_version: "test".to_owned(),
                runtime_revision: "test".to_owned(),
                luau: LuauProducer {
                    revision: "test".to_owned(),
                    bytecode_versions: vec![3],
                },
                min_runtime: "0.2.0".to_owned(),
            },
            scene_format: SceneFormat { major: 7, minor: 0 },
            required_capabilities: Vec::new(),
            scene: SceneMember {
                member: "scene".to_owned(),
                sha256: "0".repeat(64),
                size_bytes: 0,
            },
            journey: JourneyMember {
                member: "journey".to_owned(),
                sha256: "0".repeat(64),
                size_bytes: 0,
                schema_version: 1,
            },
            entry: Entry {
                screen_id: "screen".to_owned(),
            },
            screens: vec![Screen {
                screen_id: "screen".to_owned(),
                artboard_id: "artboard".to_owned(),
                artboard_name: "Root".to_owned(),
                width: 100.0,
                height: 100.0,
            }],
            text_inputs: Vec::new(),
            assets: Assets::default(),
            members: Vec::new(),
        };
        let package = write_package(&NuxPackageModel {
            manifest,
            scene: &scene,
            journey: br#"{"schemaVersion":1}"#,
            embedded_assets: Vec::new(),
            signature: SignatureSource::Signer(&*TEST_ONLY_DEV_KEYPAIR),
        })
        .expect("fixture package encodes");
        let experience_id = CString::new("scripted-apple-seam").expect("valid identity");
        let build_id = CString::new("build-scripted-apple-seam").expect("valid build");
        let key_id = TEST_ONLY_DEV_KEY_ID.as_bytes();
        let public_key = TEST_ONLY_DEV_KEYPAIR.public_key();
        let candidate_key = NuxExperienceAuthorizationKey {
            struct_size: size_u32::<NuxExperienceAuthorizationKey>(),
            key_id: bytes(key_id),
            ed25519_public_key: bytes(&public_key),
        };
        let request = NuxExperienceImportRequest {
            struct_size: size_u32::<NuxExperienceImportRequest>(),
            package_bytes: bytes(&package),
            expected_experience_id: experience_id.as_ptr(),
            expected_build_id: build_id.as_ptr(),
            candidate_keys: &candidate_key,
            candidate_key_count: 1,
            external_assets: ptr::null(),
            external_asset_count: 0,
        };
        body(&request)
    }

    #[cfg(feature = "apple-product")]
    fn copied_byte_view(view: NuxByteView) -> Vec<u8> {
        if view.len == 0 {
            return Vec::new();
        }
        assert!(!view.data.is_null(), "non-empty borrowed byte view is null");
        unsafe { slice::from_raw_parts(view.data, view.len as usize) }.to_vec()
    }

    #[cfg(feature = "apple-product")]
    fn public_output_at(result: *const NuxScreenSessionResult, index: u64) -> NuxScreenOutputView {
        let mut output: NuxScreenOutputView = unsafe { std::mem::zeroed() };
        output.struct_size = size_u32::<NuxScreenOutputView>();
        assert_eq!(
            unsafe { nux_screen_session_result_output_at(result, index, &mut output) },
            NuxStatus::Ok
        );
        output
    }

    #[cfg(feature = "apple-product")]
    fn public_value_node_at(
        result: *const NuxScreenSessionResult,
        index: u32,
    ) -> NuxScreenValueNode {
        let mut node = null_node(NUX_SCREEN_VALUE_KIND_NULL);
        assert_eq!(
            unsafe { nux_screen_session_result_value_node_at(result, u64::from(index), &mut node) },
            NuxStatus::Ok
        );
        node
    }

    #[cfg(feature = "apple-product")]
    fn public_value_edge_at(
        result: *const NuxScreenSessionResult,
        index: u32,
    ) -> NuxScreenValueEdge {
        let mut edge: NuxScreenValueEdge = unsafe { std::mem::zeroed() };
        edge.struct_size = size_u32::<NuxScreenValueEdge>();
        assert_eq!(
            unsafe { nux_screen_session_result_value_edge_at(result, u64::from(index), &mut edge) },
            NuxStatus::Ok
        );
        edge
    }

    #[cfg(feature = "apple-product")]
    fn public_object_child(
        result: *const NuxScreenSessionResult,
        object_index: u32,
        key: &[u8],
    ) -> u32 {
        let object = public_value_node_at(result, object_index);
        assert_eq!(object.kind, NUX_SCREEN_VALUE_KIND_OBJECT);
        for offset in 0..object.edge_count {
            let edge_index = object
                .first_edge
                .checked_add(offset)
                .expect("fixture edge index remains bounded");
            let edge = public_value_edge_at(result, edge_index);
            if copied_byte_view(edge.key) == key {
                return edge.node_index;
            }
        }
        panic!(
            "typed host object is missing key {:?}",
            String::from_utf8_lossy(key)
        );
    }

    #[test]
    fn exact_runtime_identity_session_layouts_are_40_and_48_bytes() {
        assert_eq!(
            std::mem::size_of::<NuxScreenConfiguredSessionDescriptor>(),
            40
        );
        assert_eq!(std::mem::size_of::<NuxScreenSessionOperation>(), 48);
    }

    #[test]
    fn legacy_session_layout_sizes_fail_before_trailing_fields_are_read() {
        let mut descriptor =
            std::mem::MaybeUninit::<NuxScreenConfiguredSessionDescriptor>::uninit();
        unsafe {
            descriptor.as_mut_ptr().cast::<u32>().write(48);
        }
        assert!(matches!(
            unsafe { copy_configured_session_descriptor(descriptor.as_ptr()) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));

        let mut operation = std::mem::MaybeUninit::<NuxScreenSessionOperation>::uninit();
        unsafe {
            operation.as_mut_ptr().cast::<u32>().write(56);
        }
        assert!(matches!(
            unsafe { copy_session_operation(operation.as_ptr()) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));
    }

    #[test]
    fn same_size_legacy_descriptor_is_rejected_before_nested_views_are_read() {
        #[repr(C)]
        struct LegacyConfiguredSessionDescriptor {
            struct_size: u32,
            legacy_required_major: u16,
            legacy_minimum_minor: u16,
            artboard_name: NuxByteView,
            player_name: NuxByteView,
        }

        let legacy = LegacyConfiguredSessionDescriptor {
            struct_size: 40,
            legacy_required_major: 1,
            legacy_minimum_minor: 5,
            artboard_name: NuxByteView {
                data: ptr::null(),
                len: 1,
            },
            player_name: NuxByteView {
                data: ptr::null(),
                len: 1,
            },
        };
        assert_eq!(std::mem::size_of_val(&legacy), 40);
        assert!(matches!(
            unsafe {
                copy_configured_session_descriptor(
                    (&raw const legacy).cast::<NuxScreenConfiguredSessionDescriptor>(),
                )
            },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));
    }

    #[test]
    fn bound_runtime_layouts_keep_the_remaining_public_contract_stable() {
        assert_eq!(std::mem::size_of::<NuxScreenSessionDescriptor>(), 40);
        assert_eq!(std::mem::size_of::<NuxFrameOperation>(), 40);
        assert_eq!(
            std::mem::size_of::<NuxScreenConfiguredSessionDescriptor>(),
            40
        );
        assert_eq!(
            std::mem::offset_of!(NuxScreenConfiguredSessionDescriptor, player_kind),
            4
        );
        assert_eq!(std::mem::size_of::<NuxScreenValueNode>(), 88);
        assert_eq!(std::mem::size_of::<NuxScreenValueEdge>(), 24);
        assert_eq!(std::mem::size_of::<NuxScreenValueArena>(), 40);
        assert_eq!(std::mem::size_of::<NuxScreenNewInstance>(), 40);
        assert_eq!(std::mem::size_of::<NuxScreenInstanceReference>(), 16);
        assert_eq!(std::mem::size_of::<NuxScreenStateMutation>(), 88);
        assert_eq!(std::mem::size_of::<NuxScreenStateBatch>(), 56);
        assert_eq!(std::mem::size_of::<NuxScreenTextRunMutation>(), 40);
        assert_eq!(std::mem::offset_of!(NuxScreenTextRunMutation, name), 8);
        assert_eq!(std::mem::offset_of!(NuxScreenTextRunMutation, text), 24);
        assert_eq!(std::mem::size_of::<NuxScreenTextRunBatch>(), 24);
        assert_eq!(std::mem::offset_of!(NuxScreenTextRunBatch, mutations), 8);
        assert_eq!(std::mem::size_of::<NuxScreenPointerEvent>(), 24);
        assert_eq!(std::mem::size_of::<NuxScreenPointerBatch>(), 24);
        assert_eq!(std::mem::size_of::<NuxScreenAdvanceOperation>(), 48);
        assert_eq!(std::mem::size_of::<NuxScreenQuery>(), 8);
        assert_eq!(std::mem::size_of::<NuxScreenSessionOperation>(), 48);
        assert_eq!(
            std::mem::offset_of!(NuxScreenSessionOperation, text_run_batch),
            40
        );
        assert_eq!(std::mem::size_of::<NuxScreenPlayerMetadataView>(), 64);
        assert_eq!(std::mem::size_of::<NuxScreenPlayerInputView>(), 32);
        assert_eq!(std::mem::size_of::<NuxScreenSchemaPropertyView>(), 80);
        assert_eq!(std::mem::size_of::<NuxScreenEnumLabelView>(), 24);
        assert_eq!(std::mem::size_of::<NuxScreenOutputView>(), 160);
        assert_eq!(
            std::mem::offset_of!(NuxScreenOutputView, payload_root_index),
            12
        );
        assert_eq!(std::mem::offset_of!(NuxScreenOutputView, has_open_url), 120);
        assert_eq!(std::mem::offset_of!(NuxScreenOutputView, open_url), 128);
        assert_eq!(
            std::mem::offset_of!(NuxScreenOutputView, open_url_target),
            144
        );
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn reported_open_url_fields_survive_core_translation_and_c_borrowing_exactly() {
        let result = configured_session_seam::result_from_core(core::FlowResult {
            outputs: vec![
                core::FlowOutput {
                    sequence: 1,
                    cycle: 1,
                    phase: core::FlowOutputPhase::ReportedEvents,
                    payload: core::FlowOutputPayload::ReportedEvent {
                        name: Some("Open".to_owned()),
                        event_type: 131,
                        url: Some("https://nuxie.example/path?x=1".to_owned()),
                        target: Some("_self".to_owned()),
                        delay_seconds: 0.0,
                        properties: Vec::new(),
                    },
                },
                core::FlowOutput {
                    sequence: 2,
                    cycle: 1,
                    phase: core::FlowOutputPhase::ReportedEvents,
                    payload: core::FlowOutputPayload::ReportedEvent {
                        name: Some("Ordinary".to_owned()),
                        event_type: 128,
                        url: None,
                        target: None,
                        delay_seconds: 0.0,
                        properties: Vec::new(),
                    },
                },
            ],
            dirty: false,
            settled: true,
            wake_after_seconds: None,
            snapshot: None,
            values: None,
            catalog: None,
            player_inputs: None,
            created_instances: Vec::new(),
        })
        .expect("valid core outputs must translate");
        assert_eq!(result.validate(), Ok(()));
        let result = Box::into_raw(Box::new(result)).cast::<NuxScreenSessionResult>();

        let mut open: NuxScreenOutputView = unsafe { std::mem::zeroed() };
        open.struct_size = size_u32::<NuxScreenOutputView>();
        assert_eq!(
            unsafe { nux_screen_session_result_output_at(result, 0, &mut open) },
            NuxStatus::Ok
        );
        assert_eq!(open.has_open_url, 1);
        assert_eq!(
            unsafe { slice::from_raw_parts(open.open_url.data, open.open_url.len as usize) },
            b"https://nuxie.example/path?x=1"
        );
        assert_eq!(
            unsafe {
                slice::from_raw_parts(open.open_url_target.data, open.open_url_target.len as usize)
            },
            b"_self"
        );

        let mut ordinary: NuxScreenOutputView = unsafe { std::mem::zeroed() };
        ordinary.struct_size = size_u32::<NuxScreenOutputView>();
        assert_eq!(
            unsafe { nux_screen_session_result_output_at(result, 1, &mut ordinary) },
            NuxStatus::Ok
        );
        assert_eq!(ordinary.has_open_url, 0);
        assert!(ordinary.open_url.data.is_null());
        assert_eq!(ordinary.open_url.len, 0);
        assert!(ordinary.open_url_target.data.is_null());
        assert_eq!(ordinary.open_url_target.len, 0);

        unsafe { nux_screen_session_result_free(result) };
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn typed_host_command_uses_an_object_root_and_empty_opaque_payload() {
        let payload = core::FlowHostValue::Object(BTreeMap::from([
            (
                "alpha".to_owned(),
                core::FlowHostValue::String("first".to_owned()),
            ),
            (
                "nested".to_owned(),
                core::FlowHostValue::List(vec![
                    core::FlowHostValue::Bool(true),
                    core::FlowHostValue::Object(BTreeMap::from([(
                        "score".to_owned(),
                        core::FlowHostValue::Number(42.5),
                    )])),
                ]),
            ),
        ]));
        let result = configured_session_seam::result_from_core(core::FlowResult {
            outputs: vec![core::FlowOutput {
                sequence: 1,
                cycle: 0,
                phase: core::FlowOutputPhase::HostWork,
                payload: core::FlowOutputPayload::HostCommand {
                    name: "created".to_owned(),
                    payload,
                },
            }],
            dirty: false,
            settled: true,
            wake_after_seconds: None,
            snapshot: None,
            values: None,
            catalog: None,
            player_inputs: None,
            created_instances: Vec::new(),
        })
        .expect("typed host output must translate");

        assert!(!result.has_values, "host payloads are not state snapshots");
        assert_eq!(result.outputs.len(), 1);
        let output = &result.outputs[0];
        assert_eq!(output.phase, NUX_SCREEN_OUTPUT_PHASE_HOST_WORK);
        assert_eq!(output.kind, NUX_SCREEN_OUTPUT_KIND_HOST_COMMAND);
        assert!(output.payload.is_empty());
        let root_index = output.payload_root_index.expect("host object root");
        let root = &result.value_arena.nodes[root_index as usize];
        assert_eq!(root.kind, NUX_SCREEN_VALUE_KIND_OBJECT);
        let root_edges = &result.value_arena.edges
            [root.first_edge as usize..(root.first_edge + root.edge_count) as usize];
        assert_eq!(
            root_edges
                .iter()
                .map(|edge| edge.key.as_slice())
                .collect::<Vec<_>>(),
            vec![b"alpha".as_slice(), b"nested".as_slice()]
        );
        let nested = &result.value_arena.nodes[root_edges[1].node_index as usize];
        assert_eq!(nested.kind, NUX_SCREEN_VALUE_KIND_LIST);
        assert_eq!(nested.edge_count, 2);
        assert_eq!(result.validate(), Ok(()));

        let mut unsorted = result.clone();
        let root = &unsorted.value_arena.nodes[root_index as usize];
        let first_edge = root.first_edge as usize;
        unsorted.value_arena.edges.swap(first_edge, first_edge + 1);
        assert_eq!(unsorted.validate(), Err(NuxStatus::RuntimeError));
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn host_command_result_validation_rejects_malformed_typed_payloads() {
        let valid = configured_session_seam::result_from_core(core::FlowResult {
            outputs: vec![core::FlowOutput {
                sequence: 1,
                cycle: 1,
                phase: core::FlowOutputPhase::HostWork,
                payload: core::FlowOutputPayload::HostCommand {
                    name: "event".to_owned(),
                    payload: core::FlowHostValue::Object(BTreeMap::from([(
                        "value".to_owned(),
                        core::FlowHostValue::Number(1.0),
                    )])),
                },
            }],
            dirty: false,
            settled: true,
            wake_after_seconds: None,
            snapshot: None,
            values: None,
            catalog: None,
            player_inputs: None,
            created_instances: Vec::new(),
        })
        .expect("valid host output translates");

        let mut missing_root = valid.clone();
        missing_root.outputs[0].payload_root_index = None;
        assert_eq!(missing_root.validate(), Err(NuxStatus::RuntimeError));

        let mut scalar_root = valid.clone();
        scalar_root.outputs[0].payload_root_index = Some(0);
        assert_eq!(scalar_root.validate(), Err(NuxStatus::RuntimeError));

        let mut wrong_phase = valid.clone();
        wrong_phase.outputs[0].phase = NUX_SCREEN_OUTPUT_PHASE_RENDER;
        assert_eq!(wrong_phase.validate(), Err(NuxStatus::RuntimeError));

        let mut empty_name = valid.clone();
        empty_name.outputs[0].name.clear();
        assert_eq!(empty_name.validate(), Err(NuxStatus::RuntimeError));

        let mut nonempty_path = valid.clone();
        nonempty_path.outputs[0].path = b"state/path".to_vec();
        assert_eq!(nonempty_path.validate(), Err(NuxStatus::RuntimeError));

        let mut instance_id = valid.clone();
        instance_id.outputs[0].instance_id = Some(7);
        assert_eq!(instance_id.validate(), Err(NuxStatus::RuntimeError));

        let mut origin_mutation_id = valid.clone();
        origin_mutation_id.outputs[0].origin_mutation_id = Some(11);
        assert_eq!(origin_mutation_id.validate(), Err(NuxStatus::RuntimeError));

        let mut event_type = valid.clone();
        event_type.outputs[0].event_type = 1;
        assert_eq!(event_type.validate(), Err(NuxStatus::RuntimeError));

        let mut event_range = valid.clone();
        event_range.outputs[0].first_event_property = 1;
        assert_eq!(event_range.validate(), Err(NuxStatus::RuntimeError));

        let mut delay = valid.clone();
        delay.outputs[0].delay_seconds = 0.25;
        assert_eq!(delay.validate(), Err(NuxStatus::RuntimeError));

        let mut open_url = valid.clone();
        open_url.outputs[0].open_url = Some(OwnedOpenUrl {
            url: b"https://example.com".to_vec(),
            target: b"_self".to_vec(),
        });
        assert_eq!(open_url.validate(), Err(NuxStatus::RuntimeError));

        let mut opaque_payload = valid.clone();
        opaque_payload.outputs[0].payload = vec![1];
        assert_eq!(opaque_payload.validate(), Err(NuxStatus::RuntimeError));

        let mut nonfinite = valid.clone();
        nonfinite.value_arena.nodes[0].number_value = f64::NAN;
        assert_eq!(nonfinite.validate(), Err(NuxStatus::RuntimeError));

        let mut null_value = valid.clone();
        null_value.value_arena.nodes[0].kind = NUX_SCREEN_VALUE_KIND_NULL;
        null_value.value_arena.nodes[0].number_value = 0.0;
        assert_eq!(null_value.validate(), Err(NuxStatus::RuntimeError));

        let mut enum_value = valid.clone();
        enum_value.value_arena.nodes[0].kind = NUX_SCREEN_VALUE_KIND_ENUM;
        enum_value.value_arena.nodes[0].number_value = 0.0;
        enum_value.value_arena.nodes[0].identity_value = 1;
        assert_eq!(enum_value.validate(), Err(NuxStatus::RuntimeError));

        let mut color_value = valid.clone();
        color_value.value_arena.nodes[0].kind = NUX_SCREEN_VALUE_KIND_COLOR;
        color_value.value_arena.nodes[0].number_value = 0.0;
        color_value.value_arena.nodes[0].color_value = 0xff00ffff;
        assert_eq!(color_value.validate(), Err(NuxStatus::RuntimeError));

        let mut view_model_value = valid.clone();
        view_model_value.value_arena.nodes[0].kind = NUX_SCREEN_VALUE_KIND_VIEW_MODEL;
        view_model_value.value_arena.nodes[0].number_value = 0.0;
        assert_eq!(view_model_value.validate(), Err(NuxStatus::RuntimeError));

        let mut schema_object = valid.clone();
        schema_object.value_arena.nodes[0].kind = NUX_SCREEN_VALUE_KIND_OBJECT;
        schema_object.value_arena.nodes[0].number_value = 0.0;
        schema_object.value_arena.nodes[0].schema_id = b"Payload".to_vec();
        assert_eq!(schema_object.validate(), Err(NuxStatus::RuntimeError));

        let mut malformed_edge = valid;
        malformed_edge.value_arena.edges[0].node_index = u32::MAX;
        assert_eq!(malformed_edge.validate(), Err(NuxStatus::RuntimeError));
    }

    #[test]
    fn result_validation_rejects_malformed_state_change_payload_roots() {
        let mut result = ScreenSessionResultHandle::empty_success();
        result.value_arena.nodes.push(OwnedValueNode {
            kind: NUX_SCREEN_VALUE_KIND_VIEW_MODEL,
            number_value: 0.0,
            color_value: 0,
            bool_value: false,
            first_edge: 0,
            edge_count: 0,
            instance_id: None,
            identity_value: 0,
            string_value: Vec::new(),
            schema_id: Vec::new(),
        });
        result.outputs.push(OwnedOutput {
            phase: NUX_SCREEN_OUTPUT_PHASE_VIEW_MODEL_CHANGES,
            kind: NUX_SCREEN_OUTPUT_KIND_VIEW_MODEL_CHANGE,
            payload_root_index: Some(0),
            sequence: 1,
            cycle: 1,
            origin_mutation_id: None,
            instance_id: Some(1),
            event_type: 0,
            first_event_property: 0,
            event_property_count: 0,
            delay_seconds: 0.0,
            name: Vec::new(),
            path: b"child".to_vec(),
            payload: Vec::new(),
            open_url: None,
        });

        assert_eq!(result.validate(), Err(NuxStatus::RuntimeError));
        result.value_arena.nodes[0].instance_id = Some(2);
        result.value_arena.nodes[0].schema_id = b"Child".to_vec();
        assert_eq!(result.validate(), Ok(()));

        result.value_arena.nodes[0].edge_count = 1;
        result.value_arena.nodes.push(OwnedValueNode {
            kind: NUX_SCREEN_VALUE_KIND_NULL,
            number_value: 0.0,
            color_value: 0,
            bool_value: false,
            first_edge: 0,
            edge_count: 0,
            instance_id: None,
            identity_value: 0,
            string_value: Vec::new(),
            schema_id: Vec::new(),
        });
        result.value_arena.edges.push(OwnedValueEdge {
            node_index: 1,
            key: b"value".to_vec(),
        });
        assert_eq!(result.validate(), Err(NuxStatus::RuntimeError));

        result.value_arena.edges.clear();
        result.value_arena.nodes.truncate(1);
        let root = &mut result.value_arena.nodes[0];
        root.kind = NUX_SCREEN_VALUE_KIND_OBJECT;
        root.edge_count = 0;
        root.instance_id = None;
        root.schema_id.clear();
        assert_eq!(
            validate_result_value_node(root),
            Ok(()),
            "the generic arena permits a zero-edge object"
        );
        assert_eq!(result.validate(), Err(NuxStatus::RuntimeError));

        result.value_arena.nodes[0].kind = NUX_SCREEN_VALUE_KIND_LIST;
        assert_eq!(result.validate(), Err(NuxStatus::RuntimeError));

        result.value_arena.nodes[0].kind = NUX_SCREEN_VALUE_KIND_STRING;
        result.value_arena.nodes[0].string_value = b"scalar".to_vec();
        assert_eq!(result.validate(), Ok(()));

        result.outputs[0].kind = NUX_SCREEN_OUTPUT_KIND_STATE_CHANGE;
        assert_eq!(result.validate(), Ok(()));
        result.value_arena.nodes[0].kind = NUX_SCREEN_VALUE_KIND_OBJECT;
        result.value_arena.nodes[0].string_value.clear();
        assert_eq!(result.validate(), Err(NuxStatus::RuntimeError));

        result.value_arena.nodes[0].kind = NUX_SCREEN_VALUE_KIND_NULL;
        result.outputs[0].kind = NUX_SCREEN_OUTPUT_KIND_REPORTED_EVENT;
        assert_eq!(result.validate(), Err(NuxStatus::RuntimeError));
    }

    #[test]
    fn result_validation_rejects_open_url_on_other_kinds_and_oversized_fields() {
        let mut result = ScreenSessionResultHandle::empty_success();
        result.outputs.push(OwnedOutput {
            phase: NUX_SCREEN_OUTPUT_PHASE_RUNTIME_ADVANCE,
            kind: NUX_SCREEN_OUTPUT_KIND_RUNTIME_ADVANCED,
            payload_root_index: None,
            sequence: 1,
            cycle: 1,
            origin_mutation_id: None,
            instance_id: None,
            event_type: 0,
            first_event_property: 0,
            event_property_count: 0,
            delay_seconds: 0.0,
            name: Vec::new(),
            path: Vec::new(),
            payload: Vec::new(),
            open_url: Some(OwnedOpenUrl {
                url: b"https://nuxie.example".to_vec(),
                target: b"_blank".to_vec(),
            }),
        });
        assert_eq!(result.validate(), Err(NuxStatus::RuntimeError));

        result.outputs[0].phase = NUX_SCREEN_OUTPUT_PHASE_REPORTED_EVENTS;
        result.outputs[0].kind = NUX_SCREEN_OUTPUT_KIND_REPORTED_EVENT;
        result.outputs[0].open_url.as_mut().unwrap().url =
            vec![b'x'; NUX_SCREEN_MAX_STRING_BYTE_LENGTH as usize + 1];
        assert_eq!(result.validate(), Err(NuxStatus::RuntimeError));

        let open_url = result.outputs[0].open_url.as_mut().unwrap();
        open_url.url.clear();
        open_url.target = vec![b'x'; NUX_SCREEN_MAX_ID_BYTE_LENGTH as usize + 1];
        assert_eq!(result.validate(), Err(NuxStatus::RuntimeError));

        result.outputs[0].open_url.as_mut().unwrap().target = b"new-window".to_vec();
        assert_eq!(result.validate(), Err(NuxStatus::RuntimeError));
    }

    #[test]
    fn configured_descriptor_rejects_wrong_size_and_malformed_selectors() {
        let mut descriptor = configured_descriptor();
        descriptor.player_kind = u32::MAX;
        assert!(matches!(
            unsafe { copy_configured_session_descriptor(&descriptor) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));
        descriptor.player_kind = NUX_SCREEN_PLAYER_SELECTOR_KIND_DEFAULT;
        descriptor.player_name = bytes(b"named");
        assert!(matches!(
            unsafe { copy_configured_session_descriptor(&descriptor) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));
        descriptor.player_name = NuxByteView::default();
        for named_kind in [
            NUX_SCREEN_PLAYER_SELECTOR_KIND_STATE_MACHINE,
            NUX_SCREEN_PLAYER_SELECTOR_KIND_LINEAR_ANIMATION,
        ] {
            descriptor.player_kind = named_kind;
            assert!(matches!(
                unsafe { copy_configured_session_descriptor(&descriptor) },
                Err(NUX_STATUS_INVALID_ARGUMENT)
            ));
        }
        descriptor.player_kind = NUX_SCREEN_PLAYER_SELECTOR_KIND_STATE_MACHINE;
        descriptor.player_name = NuxByteView {
            data: ptr::dangling(),
            len: 0,
        };
        assert!(matches!(
            unsafe { copy_configured_session_descriptor(&descriptor) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));

        descriptor.player_name = bytes(b"Machine");
        assert_eq!(
            unsafe { copy_configured_session_descriptor(&descriptor) }
                .expect("copy state-machine selector")
                .player,
            Some(OwnedPlayerSelector::StateMachine("Machine".to_owned()))
        );
        descriptor.player_kind = NUX_SCREEN_PLAYER_SELECTOR_KIND_LINEAR_ANIMATION;
        assert_eq!(
            unsafe { copy_configured_session_descriptor(&descriptor) }
                .expect("copy animation selector")
                .player,
            Some(OwnedPlayerSelector::LinearAnimation("Machine".to_owned()))
        );

        descriptor.struct_size = size_u32::<NuxScreenConfiguredSessionDescriptor>() + 8;
        assert!(matches!(
            unsafe { copy_configured_session_descriptor(&descriptor) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));
    }

    #[test]
    fn session_operation_accepts_the_exact_current_layout() {
        let advance = NuxScreenAdvanceOperation {
            struct_size: size_u32::<NuxScreenAdvanceOperation>(),
            timestamp_seconds: 0.0,
            delta_seconds: 0.0,
            render: 0,
            apple_drawable: ptr::null_mut(),
            completion_context: ptr::null_mut(),
            completion_callback: None,
        };
        let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_ADVANCE);
        request.advance = &advance;
        assert!(matches!(
            unsafe { copy_session_operation(&request) },
            Ok(OwnedSessionOperation::Advance(_))
        ));
        request.struct_size = size_u32::<NuxScreenSessionOperation>() + 8;
        assert!(matches!(
            unsafe { copy_session_operation(&request) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));
    }

    #[test]
    fn text_run_batch_copy_preserves_literal_names_empty_text_and_exclusive_tagging() {
        let mutation = NuxScreenTextRunMutation {
            struct_size: size_u32::<NuxScreenTextRunMutation>(),
            name: bytes(b"group//headline"),
            text: bytes(b""),
        };
        let batch = NuxScreenTextRunBatch {
            struct_size: size_u32::<NuxScreenTextRunBatch>(),
            mutations: &mutation,
            mutation_count: 1,
        };
        assert_eq!(
            unsafe { copy_text_run_batch(&batch) }.expect("copy text-run batch"),
            vec![OwnedTextRunMutation {
                name: b"group//headline".to_vec(),
                text: Vec::new(),
            }]
        );

        let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_TEXT_RUN_BATCH);
        request.text_run_batch = &batch;
        assert!(matches!(
            unsafe { copy_session_operation(&request) },
            Ok(OwnedSessionOperation::TextRunBatch(mutations))
                if mutations.len() == 1
                    && mutations.first().is_some_and(|mutation| {
                        mutation.name == b"group//headline" && mutation.text.is_empty()
                    })
        ));

        let query = NuxScreenQueryBatch {
            struct_size: size_u32::<NuxScreenQueryBatch>(),
            queries: ptr::null(),
            query_count: 0,
        };
        request.query_batch = &query;
        assert!(matches!(
            unsafe { copy_session_operation(&request) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));
    }

    #[test]
    fn text_run_batch_copy_enforces_exact_elements_and_published_byte_bounds() {
        let name = vec![b'n'; NUX_SCREEN_MAX_ID_BYTE_LENGTH as usize + 1];
        let text = vec![b't'; NUX_SCREEN_MAX_STRING_BYTE_LENGTH as usize + 1];
        let mut mutation = NuxScreenTextRunMutation {
            struct_size: size_u32::<NuxScreenTextRunMutation>(),
            name: bytes(b"headline"),
            text: bytes(b"updated"),
        };
        let mut batch = NuxScreenTextRunBatch {
            struct_size: size_u32::<NuxScreenTextRunBatch>(),
            mutations: &mutation,
            mutation_count: 1,
        };

        mutation.struct_size -= 1;
        assert!(matches!(
            unsafe { copy_text_run_batch(&batch) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));
        mutation.struct_size = size_u32::<NuxScreenTextRunMutation>();
        mutation.name = bytes(&name);
        assert!(matches!(
            unsafe { copy_text_run_batch(&batch) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));
        mutation.name = bytes(b"headline");
        mutation.text = bytes(&text);
        assert!(matches!(
            unsafe { copy_text_run_batch(&batch) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));

        let one_mib = vec![b't'; NUX_SCREEN_MAX_STRING_BYTE_LENGTH as usize];
        mutation.text = bytes(&one_mib);
        let mutations = [mutation; 5];
        batch.mutations = mutations.as_ptr();
        batch.mutation_count = mutations.len() as u64;
        assert!(matches!(
            unsafe { copy_text_run_batch(&batch) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));

        batch.mutations = ptr::dangling();
        batch.mutation_count = NUX_SCREEN_MAX_BATCH_ITEM_COUNT + 1;
        assert!(matches!(
            unsafe { copy_text_run_batch(&batch) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn configured_text_run_batch_crosses_the_public_abi_atomically_and_recovers_after_not_found() {
        let worker = match RuntimeWorker::spawn(text_run_apple_seam_artifact()) {
            Ok(worker) => worker,
            Err(_) => panic!("import authored text-run fixture"),
        };
        let context = Box::into_raw(Box::new(ExperienceRuntimeContextHandle { worker }))
            .cast::<NuxExperienceContext>();
        let descriptor = configured_descriptor();
        let mut session = ptr::null_mut();
        let mut create_result = ptr::null_mut();
        assert_eq!(
            unsafe {
                nux_screen_session_create_configured(
                    context,
                    &descriptor,
                    &mut session,
                    &mut create_result,
                )
            },
            NuxStatus::Ok
        );
        assert!(!session.is_null());
        assert_eq!(
            unsafe { nux_screen_session_result_status(create_result) },
            NuxStatus::Ok
        );
        unsafe { nux_screen_session_result_free(create_result) };

        let perform_text_batch = |pairs: &[(&[u8], &[u8])]| {
            let mutations = pairs
                .iter()
                .map(|(name, text)| NuxScreenTextRunMutation {
                    struct_size: size_u32::<NuxScreenTextRunMutation>(),
                    name: bytes(name),
                    text: bytes(text),
                })
                .collect::<Vec<_>>();
            let batch = NuxScreenTextRunBatch {
                struct_size: size_u32::<NuxScreenTextRunBatch>(),
                mutations: mutations.as_ptr(),
                mutation_count: mutations.len() as u64,
            };
            let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_TEXT_RUN_BATCH);
            request.text_run_batch = &batch;
            let mut result = ptr::null_mut();
            let status = unsafe { nux_screen_session_perform(session, &request, &mut result) };
            (status, result)
        };

        let (status, changed_result) = perform_text_batch(&[(b"headline", b"updated")]);
        assert_eq!(status, NuxStatus::Ok);
        assert_eq!(
            unsafe { nux_screen_session_result_status(changed_result) },
            NuxStatus::Ok
        );
        assert!(unsafe { nux_screen_session_result_is_dirty(changed_result) });
        let mut wake_after = f64::NAN;
        assert_eq!(
            unsafe {
                nux_screen_session_result_wake_after_seconds(changed_result, &mut wake_after)
            },
            NuxStatus::Ok
        );
        assert_eq!(wake_after, 0.0);
        unsafe { nux_screen_session_result_free(changed_result) };

        let (status, unchanged_result) = perform_text_batch(&[(b"headline", b"updated")]);
        assert_eq!(status, NuxStatus::Ok);
        assert!(!unsafe { nux_screen_session_result_is_dirty(unchanged_result) });
        assert_eq!(
            unsafe {
                nux_screen_session_result_wake_after_seconds(unchanged_result, &mut wake_after)
            },
            NuxStatus::NotFound
        );
        unsafe { nux_screen_session_result_free(unchanged_result) };

        let (status, missing_result) =
            perform_text_batch(&[(b"headline", b"must-not-commit"), (b"missing", b"ignored")]);
        assert_eq!(status, NuxStatus::NotFound);
        assert_eq!(
            unsafe { nux_screen_session_result_status(missing_result) },
            NuxStatus::NotFound
        );
        assert!(!unsafe { nux_screen_session_result_is_dirty(missing_result) });
        assert_eq!(
            unsafe { nux_screen_session_result_diagnostic_count(missing_result) },
            1
        );
        let mut diagnostic = NuxDiagnosticView::default();
        assert_eq!(
            unsafe { nux_screen_session_result_diagnostic_at(missing_result, 0, &mut diagnostic) },
            NuxStatus::Ok
        );
        assert_eq!(
            copied_byte_view(diagnostic.code),
            diagnostic_code_for_status(NuxStatus::NotFound)
        );
        assert_eq!(
            copied_byte_view(diagnostic.message),
            b"root TextValueRun 'missing' was not found"
        );
        unsafe { nux_screen_session_result_free(missing_result) };

        // The rejected batch did not commit its first write or poison the
        // session: replaying the prior value remains a clean success.
        let (status, recovered_result) = perform_text_batch(&[(b"headline", b"updated")]);
        assert_eq!(status, NuxStatus::Ok);
        assert_eq!(
            unsafe { nux_screen_session_result_status(recovered_result) },
            NuxStatus::Ok
        );
        assert!(!unsafe { nux_screen_session_result_is_dirty(recovered_result) });
        assert_eq!(
            unsafe {
                nux_screen_session_result_wake_after_seconds(recovered_result, &mut wake_after)
            },
            NuxStatus::NotFound
        );
        unsafe {
            nux_screen_session_result_free(recovered_result);
            nux_screen_session_free(session);
            nux_experience_context_free(context);
        }
    }

    #[test]
    fn value_arena_rejects_cycles_nonfinite_values_and_total_payload_overflow() {
        let edge = NuxScreenValueEdge {
            struct_size: size_u32::<NuxScreenValueEdge>(),
            node_index: 0,
            key: bytes(b"self"),
        };
        let mut object = null_node(NUX_SCREEN_VALUE_KIND_OBJECT);
        object.edge_count = 1;
        let arena = NuxScreenValueArena {
            struct_size: size_u32::<NuxScreenValueArena>(),
            nodes: &object,
            node_count: 1,
            edges: &edge,
            edge_count: 1,
        };
        assert!(matches!(
            unsafe { copy_value_arena(&arena, &mut PayloadBudget::default()) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));

        let mut number = null_node(NUX_SCREEN_VALUE_KIND_NUMBER);
        number.number_value = f64::NAN;
        let arena = NuxScreenValueArena {
            struct_size: size_u32::<NuxScreenValueArena>(),
            nodes: &number,
            node_count: 1,
            edges: ptr::null(),
            edge_count: 0,
        };
        assert!(matches!(
            unsafe { copy_value_arena(&arena, &mut PayloadBudget::default()) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));

        let mut overflow_number = null_node(NUX_SCREEN_VALUE_KIND_NUMBER);
        overflow_number.number_value = f64::MAX;
        let arena = NuxScreenValueArena {
            nodes: &overflow_number,
            ..arena
        };
        assert!(matches!(
            unsafe { copy_value_arena(&arena, &mut PayloadBudget::default()) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));

        let megabyte = vec![b'x'; NUX_SCREEN_MAX_STRING_BYTE_LENGTH as usize];
        let nodes = (0..5)
            .map(|_| {
                let mut node = null_node(NUX_SCREEN_VALUE_KIND_STRING);
                node.string_value = bytes(&megabyte);
                node
            })
            .collect::<Vec<_>>();
        let arena = NuxScreenValueArena {
            struct_size: size_u32::<NuxScreenValueArena>(),
            nodes: nodes.as_ptr(),
            node_count: nodes.len() as u64,
            edges: ptr::null(),
            edge_count: 0,
        };
        assert!(matches!(
            unsafe { copy_value_arena(&arena, &mut PayloadBudget::default()) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));
    }

    #[test]
    fn value_depth_counts_the_root_at_zero() {
        let arena_with_edge_depth = |edge_depth: usize| {
            let mut nodes = (0..=edge_depth)
                .map(|_| null_node(NUX_SCREEN_VALUE_KIND_LIST))
                .collect::<Vec<_>>();
            let edges = (0..edge_depth)
                .map(|index| NuxScreenValueEdge {
                    struct_size: size_u32::<NuxScreenValueEdge>(),
                    node_index: (index + 1) as u32,
                    key: NuxByteView::default(),
                })
                .collect::<Vec<_>>();
            for (index, node) in nodes.iter_mut().take(edge_depth).enumerate() {
                node.first_edge = index as u32;
                node.edge_count = 1;
            }
            (nodes, edges)
        };

        let (nodes, edges) = arena_with_edge_depth(NUX_SCREEN_MAX_VALUE_DEPTH as usize);
        let arena = NuxScreenValueArena {
            struct_size: size_u32::<NuxScreenValueArena>(),
            nodes: nodes.as_ptr(),
            node_count: nodes.len() as u64,
            edges: edges.as_ptr(),
            edge_count: edges.len() as u64,
        };
        assert!(unsafe { copy_value_arena(&arena, &mut PayloadBudget::default()) }.is_ok());

        let (nodes, edges) = arena_with_edge_depth(NUX_SCREEN_MAX_VALUE_DEPTH as usize + 1);
        let arena = NuxScreenValueArena {
            nodes: nodes.as_ptr(),
            node_count: nodes.len() as u64,
            edges: edges.as_ptr(),
            edge_count: edges.len() as u64,
            ..arena
        };
        assert!(matches!(
            unsafe { copy_value_arena(&arena, &mut PayloadBudget::default()) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));
    }

    #[test]
    fn pointer_and_operation_bounds_fail_before_the_worker_seam() {
        let event = NuxScreenPointerEvent {
            struct_size: size_u32::<NuxScreenPointerEvent>(),
            kind: NUX_SCREEN_POINTER_EVENT_KIND_DOWN,
            pointer_id: 1,
            x: 0.0,
            y: 0.0,
            timestamp_seconds: 12.5,
        };
        assert_eq!(
            unsafe {
                copy_pointer_batch(&NuxScreenPointerBatch {
                    struct_size: size_u32::<NuxScreenPointerBatch>(),
                    events: &event,
                    event_count: 1,
                })
            }
            .expect("valid pointer event copies"),
            [OwnedPointerEvent {
                kind: NUX_SCREEN_POINTER_EVENT_KIND_DOWN,
                pointer_id: 1,
                x: 0.0,
                y: 0.0,
                timestamp_seconds: 12.5,
            }]
        );
        let batch = NuxScreenPointerBatch {
            struct_size: size_u32::<NuxScreenPointerBatch>(),
            events: &event,
            event_count: NUX_SCREEN_MAX_POINTER_COUNT + 1,
        };
        assert!(matches!(
            unsafe { copy_pointer_batch(&batch) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));

        let mut invalid_event = event;
        invalid_event.timestamp_seconds = -1.0;
        let batch = NuxScreenPointerBatch {
            struct_size: size_u32::<NuxScreenPointerBatch>(),
            events: &invalid_event,
            event_count: 1,
        };
        assert!(matches!(
            unsafe { copy_pointer_batch(&batch) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));

        invalid_event = event;
        invalid_event.pointer_id = 0;
        let batch = NuxScreenPointerBatch {
            struct_size: size_u32::<NuxScreenPointerBatch>(),
            events: &invalid_event,
            event_count: 1,
        };
        assert!(matches!(
            unsafe { copy_pointer_batch(&batch) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));

        let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_POINTER_BATCH);
        request.pointer_batch = &batch;
        request.query_batch = ptr::dangling();
        assert!(matches!(
            unsafe { copy_session_operation(&request) },
            Err(NUX_STATUS_INVALID_ARGUMENT)
        ));
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn state_batch_is_fully_validated_before_the_worker_seam() {
        let mut value = null_node(NUX_SCREEN_VALUE_KIND_NUMBER);
        value.number_value = 42.0;
        let arena = NuxScreenValueArena {
            struct_size: size_u32::<NuxScreenValueArena>(),
            nodes: &value,
            node_count: 1,
            edges: ptr::null(),
            edge_count: 0,
        };
        let mutation = NuxScreenStateMutation {
            struct_size: size_u32::<NuxScreenStateMutation>(),
            kind: NUX_SCREEN_STATE_MUTATION_KIND_SET,
            instance: NuxScreenInstanceReference {
                kind: NUX_SCREEN_INSTANCE_REFERENCE_KIND_EXISTING,
                local_id: 0,
                instance_id: 7,
            },
            item: NuxScreenInstanceReference {
                kind: 0,
                local_id: 0,
                instance_id: 0,
            },
            path: bytes(b"score"),
            input_name: NuxByteView::default(),
            value_root_index: 0,
            index: 0,
            other_index: 0,
        };
        let batch = NuxScreenStateBatch {
            struct_size: size_u32::<NuxScreenStateBatch>(),
            has_host_mutation_id: 1,
            host_mutation_id: 99,
            value_arena: &arena,
            new_instances: ptr::null(),
            new_instance_count: 0,
            mutations: &mutation,
            mutation_count: 1,
        };
        let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_STATE_BATCH);
        request.state_batch = &batch;
        let mut result = ptr::null_mut();

        assert_eq!(
            unsafe { nux_screen_session_perform(ptr::null(), &request, &mut result) },
            NuxStatus::NullArgument,
            "a valid copied batch reaches live-session validation"
        );
        unsafe { nux_screen_session_result_free(result) };

        let present_zero_batch = NuxScreenStateBatch {
            has_host_mutation_id: 1,
            host_mutation_id: 0,
            ..batch
        };
        request.state_batch = &present_zero_batch;
        result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(ptr::null(), &request, &mut result) },
            NuxStatus::NullArgument,
            "the presence bit preserves host mutation ID zero"
        );
        unsafe { nux_screen_session_result_free(result) };

        let invalid_batch = NuxScreenStateBatch {
            has_host_mutation_id: 0,
            ..batch
        };
        request.state_batch = &invalid_batch;
        result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(ptr::null(), &request, &mut result) },
            NuxStatus::InvalidArgument,
            "noncanonical optional IDs are rejected before worker dispatch"
        );
        unsafe { nux_screen_session_result_free(result) };

        let new_instance = NuxScreenNewInstance {
            struct_size: size_u32::<NuxScreenNewInstance>(),
            local_id: 0,
            schema_name: NuxByteView::default(),
            authored_instance_name: NuxByteView::default(),
        };
        let instances = vec![new_instance; 2_048];
        let mutations = vec![mutation; 2_049];
        let oversized_batch = NuxScreenStateBatch {
            new_instances: instances.as_ptr(),
            new_instance_count: instances.len() as u64,
            mutations: mutations.as_ptr(),
            mutation_count: mutations.len() as u64,
            ..batch
        };
        request.state_batch = &oversized_batch;
        result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(ptr::null(), &request, &mut result) },
            NuxStatus::InvalidArgument,
            "new instances and mutations share the 4096-item batch cap"
        );
        unsafe { nux_screen_session_result_free(result) };
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn player_input_mutations_require_a_name_and_matching_scalar_kind() {
        let mut value = null_node(NUX_SCREEN_VALUE_KIND_BOOL);
        value.bool_value = 1;
        let arena = NuxScreenValueArena {
            struct_size: size_u32::<NuxScreenValueArena>(),
            nodes: &value,
            node_count: 1,
            edges: ptr::null(),
            edge_count: 0,
        };
        let zero_reference = NuxScreenInstanceReference {
            kind: 0,
            local_id: 0,
            instance_id: 0,
        };
        let mutation = NuxScreenStateMutation {
            struct_size: size_u32::<NuxScreenStateMutation>(),
            kind: NUX_SCREEN_STATE_MUTATION_KIND_SET_INPUT_BOOL,
            instance: zero_reference,
            item: zero_reference,
            path: NuxByteView::default(),
            input_name: bytes(b"enabled"),
            value_root_index: 0,
            index: 0,
            other_index: 0,
        };
        let perform_without_session = |mutation: &NuxScreenStateMutation| {
            let batch = NuxScreenStateBatch {
                struct_size: size_u32::<NuxScreenStateBatch>(),
                has_host_mutation_id: 0,
                host_mutation_id: 0,
                value_arena: &arena,
                new_instances: ptr::null(),
                new_instance_count: 0,
                mutations: mutation,
                mutation_count: 1,
            };
            let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_STATE_BATCH);
            request.state_batch = &batch;
            let mut result = ptr::null_mut();
            let status = unsafe { nux_screen_session_perform(ptr::null(), &request, &mut result) };
            unsafe { nux_screen_session_result_free(result) };
            status
        };

        assert_eq!(perform_without_session(&mutation), NuxStatus::NullArgument);

        let wrong_kind = NuxScreenStateMutation {
            kind: NUX_SCREEN_STATE_MUTATION_KIND_SET_INPUT_NUMBER,
            ..mutation
        };
        assert_eq!(
            perform_without_session(&wrong_kind),
            NuxStatus::InvalidArgument
        );

        let missing_name = NuxScreenStateMutation {
            input_name: NuxByteView::default(),
            ..mutation
        };
        assert_eq!(
            perform_without_session(&missing_name),
            NuxStatus::InvalidArgument
        );

        let oversized_name = vec![b'x'; NUX_SCREEN_MAX_ID_BYTE_LENGTH as usize + 1];
        let oversized = NuxScreenStateMutation {
            input_name: bytes(&oversized_name),
            ..mutation
        };
        assert_eq!(
            perform_without_session(&oversized),
            NuxStatus::InvalidArgument
        );
    }

    unsafe extern "C" fn count_completion(context: *mut c_void) {
        let counter = unsafe { &*context.cast::<AtomicUsize>() };
        counter.fetch_add(1, Ordering::SeqCst);
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn rejected_advance_consumes_the_completion_exactly_once() {
        let counter = AtomicUsize::new(0);
        let advance = NuxScreenAdvanceOperation {
            struct_size: size_u32::<NuxScreenAdvanceOperation>(),
            timestamp_seconds: 1.0,
            delta_seconds: 0.0,
            render: 1,
            apple_drawable: ptr::dangling_mut(),
            completion_context: (&counter as *const AtomicUsize).cast_mut().cast(),
            completion_callback: Some(count_completion),
        };
        let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_ADVANCE);
        request.advance = &advance;
        let mut result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(ptr::null(), &request, &mut result) },
            NuxStatus::NullArgument
        );
        assert_eq!(counter.load(Ordering::SeqCst), 1);
        assert!(!result.is_null());
        unsafe { nux_screen_session_result_free(result) };
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn advance_rejects_noncanonical_render_flags_before_worker_dispatch() {
        let advance = NuxScreenAdvanceOperation {
            struct_size: size_u32::<NuxScreenAdvanceOperation>(),
            timestamp_seconds: 1.0,
            delta_seconds: 0.0,
            render: 2,
            apple_drawable: ptr::null_mut(),
            completion_context: ptr::null_mut(),
            completion_callback: None,
        };
        let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_ADVANCE);
        request.advance = &advance;
        let mut result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(ptr::null(), &request, &mut result) },
            NuxStatus::InvalidArgument
        );
        unsafe { nux_screen_session_result_free(result) };
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn configured_create_and_perform_preserve_flow_failure_diagnostic_codes() {
        let cases = [
            (
                core::FlowSessionErrorKind::ScriptResourceExceeded,
                SCRIPT_RESOURCE_DIAGNOSTIC_CODE,
            ),
            (
                core::FlowSessionErrorKind::ResultLimitExceeded,
                RESULT_LIMIT_DIAGNOSTIC_CODE,
            ),
            (
                core::FlowSessionErrorKind::Runtime,
                diagnostic_code_for_status(NuxStatus::RuntimeError),
            ),
        ];

        for (kind, expected_code) in cases {
            let mut creation_result = ptr::null_mut();
            assert_eq!(
                write_session_runtime_failure(
                    &mut creation_result,
                    RuntimeFailure::screen_session(kind, "configured creation failed"),
                ),
                NuxStatus::RuntimeError
            );
            assert_session_diagnostic_code(creation_result, expected_code);
            unsafe { nux_screen_session_result_free(creation_result) };

            let perform_result =
                Box::into_raw(Box::new(ScreenSessionResultHandle::from_runtime_failure(
                    RuntimeFailure::screen_session(kind, "configured perform failed"),
                )))
                .cast::<NuxScreenSessionResult>();
            assert_session_diagnostic_code(perform_result, expected_code);
            unsafe { nux_screen_session_result_free(perform_result) };
        }
    }

    #[cfg(feature = "apple-product")]
    fn assert_session_diagnostic_code(result: *const NuxScreenSessionResult, expected_code: &[u8]) {
        assert_eq!(
            unsafe { nux_screen_session_result_status(result) },
            NuxStatus::RuntimeError
        );
        assert_eq!(
            unsafe { nux_screen_session_result_diagnostic_count(result) },
            1
        );
        let mut diagnostic = NuxDiagnosticView::default();
        assert_eq!(
            unsafe { nux_screen_session_result_diagnostic_at(result, 0, &mut diagnostic) },
            NuxStatus::Ok
        );
        let code =
            unsafe { slice::from_raw_parts(diagnostic.code.data, diagnostic.code.len as usize) };
        assert_eq!(code, expected_code);
    }

    #[test]
    fn result_views_borrow_owned_storage_until_explicit_free() {
        let mut result = ScreenSessionResultHandle::empty_success();
        result.has_player_inputs = true;
        result.player_metadata = Some(OwnedPlayerMetadata {
            kind: NUX_SCREEN_PLAYER_KIND_STATIC,
            selection: NUX_SCREEN_PLAYER_SELECTION_STATIC,
            player_index: None,
            artboard_name: b"Owned Artboard".to_vec(),
            player_name: Vec::new(),
            min_x: -10.0,
            min_y: 4.0,
            max_x: 90.0,
            max_y: 54.0,
        });
        result.value_arena.nodes.push(OwnedValueNode {
            kind: NUX_SCREEN_VALUE_KIND_BOOL,
            number_value: 0.0,
            color_value: 0,
            bool_value: true,
            first_edge: 0,
            edge_count: 0,
            instance_id: None,
            identity_value: 0,
            string_value: Vec::new(),
            schema_id: Vec::new(),
        });
        result.player_inputs.push(OwnedPlayerInput {
            kind: NUX_SCREEN_PLAYER_INPUT_KIND_BOOL,
            value_root_index: 0,
            name: b"enabled".to_vec(),
        });
        let result = Box::into_raw(Box::new(result)).cast::<NuxScreenSessionResult>();
        let mut metadata: NuxScreenPlayerMetadataView = unsafe { std::mem::zeroed() };
        metadata.struct_size = size_u32::<NuxScreenPlayerMetadataView>();
        assert_eq!(
            unsafe { nux_screen_session_result_player_metadata(result, &mut metadata) },
            NuxStatus::Ok
        );
        let copied = unsafe {
            slice::from_raw_parts(
                metadata.artboard_name.data,
                metadata.artboard_name.len as usize,
            )
        }
        .to_vec();
        assert_eq!(copied, b"Owned Artboard");
        assert_eq!(metadata.min_x, -10.0);
        assert_eq!(metadata.selection, NUX_SCREEN_PLAYER_SELECTION_STATIC);
        assert_eq!(metadata.player_index, u32::MAX);
        let mut input: NuxScreenPlayerInputView = unsafe { std::mem::zeroed() };
        input.struct_size = size_u32::<NuxScreenPlayerInputView>();
        assert_eq!(
            unsafe { nux_screen_session_result_player_input_at(result, 0, &mut input) },
            NuxStatus::Ok
        );
        assert_eq!(input.kind, NUX_SCREEN_PLAYER_INPUT_KIND_BOOL);
        let _noise = vec![0xA5_u8; 64 * 1024];
        let borrowed = unsafe {
            slice::from_raw_parts(
                metadata.artboard_name.data,
                metadata.artboard_name.len as usize,
            )
        };
        assert_eq!(borrowed, b"Owned Artboard");
        let input_name = unsafe { slice::from_raw_parts(input.name.data, input.name.len as usize) };
        assert_eq!(input_name, b"enabled");
        unsafe { nux_screen_session_result_free(result) };
    }

    #[test]
    fn result_presence_accessors_distinguish_absent_from_present_empty_snapshots() {
        let absent = Box::into_raw(Box::new(ScreenSessionResultHandle::empty_success()))
            .cast::<NuxScreenSessionResult>();
        assert!(!unsafe { nux_screen_session_result_has_values(absent) });
        assert!(!unsafe { nux_screen_session_result_has_catalog(absent) });
        assert!(!unsafe { nux_screen_session_result_has_player_inputs(absent) });
        unsafe { nux_screen_session_result_free(absent) };

        let mut present = ScreenSessionResultHandle::empty_success();
        present.has_values = true;
        present.has_catalog = true;
        present.has_player_inputs = true;
        let present = Box::into_raw(Box::new(present)).cast::<NuxScreenSessionResult>();
        assert!(unsafe { nux_screen_session_result_has_values(present) });
        assert!(unsafe { nux_screen_session_result_has_catalog(present) });
        assert!(unsafe { nux_screen_session_result_has_player_inputs(present) });
        assert_eq!(
            unsafe { nux_screen_session_result_value_root_count(present) },
            0
        );
        assert_eq!(
            unsafe { nux_screen_session_result_schema_count(present) },
            0
        );
        assert_eq!(
            unsafe { nux_screen_session_result_player_input_count(present) },
            0
        );
        unsafe { nux_screen_session_result_free(present) };

        assert!(!unsafe { nux_screen_session_result_has_values(ptr::null()) });
        assert!(!unsafe { nux_screen_session_result_has_catalog(ptr::null()) });
        assert!(!unsafe { nux_screen_session_result_has_player_inputs(ptr::null()) });
    }

    #[test]
    fn result_rejects_output_sequence_or_phase_regression_but_allows_new_cycles() {
        let mut result = ScreenSessionResultHandle::empty_success();
        let output = |sequence, cycle, phase| OwnedOutput {
            phase,
            kind: NUX_SCREEN_OUTPUT_KIND_RUNTIME_ADVANCED,
            payload_root_index: None,
            sequence,
            cycle,
            origin_mutation_id: None,
            instance_id: None,
            event_type: 0,
            first_event_property: 0,
            event_property_count: 0,
            delay_seconds: 0.0,
            name: Vec::new(),
            path: Vec::new(),
            payload: Vec::new(),
            open_url: None,
        };
        result.outputs = vec![
            output(1, 1, NUX_SCREEN_OUTPUT_PHASE_HOST_WORK),
            output(2, 2, NUX_SCREEN_OUTPUT_PHASE_REPORTED_EVENTS),
        ];
        assert_eq!(result.validate(), Ok(()));
        result.outputs[1].sequence = 1;
        assert_eq!(result.validate(), Err(NuxStatus::RuntimeError));
        result.outputs[1].sequence = 2;
        result.outputs[1].cycle = 1;
        assert_eq!(result.validate(), Err(NuxStatus::RuntimeError));
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn exported_configured_operation_catches_a_worker_panic_and_isolates_its_session() {
        let worker = match RuntimeWorker::spawn(text_run_apple_seam_artifact()) {
            Ok(worker) => worker,
            Err(_) => panic!("import configured-session panic fixture"),
        };
        let context = Box::into_raw(Box::new(ExperienceRuntimeContextHandle {
            worker: Arc::clone(&worker),
        }))
        .cast::<NuxExperienceContext>();
        let descriptor = configured_descriptor();

        let create_session = || {
            let mut session = ptr::null_mut();
            let mut creation = ptr::null_mut();
            assert_eq!(
                unsafe {
                    nux_screen_session_create_configured(
                        context,
                        &descriptor,
                        &mut session,
                        &mut creation,
                    )
                },
                NuxStatus::Ok
            );
            assert!(!session.is_null());
            assert_eq!(
                unsafe { nux_screen_session_result_status(creation) },
                NuxStatus::Ok
            );
            unsafe { nux_screen_session_result_free(creation) };
            session
        };
        let affected = create_session();
        let sibling = create_session();
        let affected_handle = unsafe { &*affected.cast::<ScreenSessionHandle>() };
        let affected_id = affected_handle.token.id;
        affected_handle
            .token
            .worker
            .call(Some(affected_id), move |state| {
                let session = state.session_mut(affected_id)?;
                session.panic_on_next_configured_operation = true;
                Ok::<(), RuntimeFailure>(())
            })
            .expect("worker accepts the test-only panic seam")
            .expect("affected session remains live before the panic");

        let advance = NuxScreenAdvanceOperation {
            struct_size: size_u32::<NuxScreenAdvanceOperation>(),
            timestamp_seconds: 0.25,
            delta_seconds: 0.25,
            render: 0,
            apple_drawable: ptr::null_mut(),
            completion_context: ptr::null_mut(),
            completion_callback: None,
        };
        let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_ADVANCE);
        request.advance = &advance;

        let mut panic_result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(affected, &request, &mut panic_result) },
            NuxStatus::RuntimeError
        );
        assert!(!panic_result.is_null());
        assert_eq!(
            unsafe { nux_screen_session_result_surface_disposition(panic_result) },
            NUX_SURFACE_DISPOSITION_FATAL
        );
        assert_eq!(
            unsafe { nux_screen_session_result_diagnostic_count(panic_result) },
            1
        );
        let mut diagnostic = NuxDiagnosticView::default();
        assert_eq!(
            unsafe { nux_screen_session_result_diagnostic_at(panic_result, 0, &mut diagnostic) },
            NuxStatus::Ok
        );
        assert_eq!(diagnostic.severity, NUX_DIAGNOSTIC_SEVERITY_FATAL);
        assert_eq!(
            copied_byte_view(diagnostic.code),
            diagnostic_code_for_status(NuxStatus::RuntimeError)
        );
        assert_eq!(
            copied_byte_view(diagnostic.message),
            PANIC_DIAGNOSTIC.as_bytes()
        );
        unsafe { nux_screen_session_result_free(panic_result) };

        let mut terminal_retry = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(affected, &request, &mut terminal_retry) },
            NuxStatus::RuntimeError
        );
        let mut terminal_diagnostic = NuxDiagnosticView::default();
        assert_eq!(
            unsafe {
                nux_screen_session_result_diagnostic_at(terminal_retry, 0, &mut terminal_diagnostic)
            },
            NuxStatus::Ok
        );
        assert_eq!(
            copied_byte_view(terminal_diagnostic.message),
            PANIC_DIAGNOSTIC.as_bytes()
        );
        unsafe { nux_screen_session_result_free(terminal_retry) };

        let mut sibling_result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(sibling, &request, &mut sibling_result) },
            NuxStatus::Ok
        );
        assert_eq!(
            unsafe { nux_screen_session_result_status(sibling_result) },
            NuxStatus::Ok
        );
        assert!(
            (0..unsafe { nux_screen_session_result_output_count(sibling_result) })
                .map(|index| public_output_at(sibling_result, index))
                .any(|output| output.kind == NUX_SCREEN_OUTPUT_KIND_RUNTIME_ADVANCED),
            "the sibling must complete a real configured advance"
        );

        unsafe {
            nux_screen_session_result_free(sibling_result);
            nux_screen_session_free(sibling);
            nux_screen_session_free(affected);
            nux_experience_context_free(context);
        }
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn configured_device_loss_preflight_does_not_advance_or_emit_outputs() {
        let worker = match RuntimeWorker::spawn(text_run_apple_seam_artifact()) {
            Ok(worker) => worker,
            Err(_) => panic!("import configured-session device-loss fixture"),
        };
        let context = Box::into_raw(Box::new(ExperienceRuntimeContextHandle {
            worker: Arc::clone(&worker),
        }))
        .cast::<NuxExperienceContext>();
        let descriptor = configured_descriptor();
        let mut session = ptr::null_mut();
        let mut creation = ptr::null_mut();
        assert_eq!(
            unsafe {
                nux_screen_session_create_configured(
                    context,
                    &descriptor,
                    &mut session,
                    &mut creation,
                )
            },
            NuxStatus::Ok
        );
        unsafe { nux_screen_session_result_free(creation) };

        let handle = unsafe { &*session.cast::<ScreenSessionHandle>() };
        let session_id = handle.token.id;
        handle
            .token
            .worker
            .call(Some(session_id), move |state| {
                state.attach_surface(session_id, 8, 8)?;
                let session = state.session_mut(session_id)?;
                session.injected_device_loss = true;
                Ok::<(), RuntimeFailure>(())
            })
            .expect("worker accepts the test-only device-loss seam")
            .expect("configured session remains live before loss");

        let advance = NuxScreenAdvanceOperation {
            struct_size: size_u32::<NuxScreenAdvanceOperation>(),
            timestamp_seconds: 0.25,
            delta_seconds: 0.25,
            render: 1,
            apple_drawable: ptr::null_mut(),
            completion_context: ptr::null_mut(),
            completion_callback: None,
        };
        let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_ADVANCE);
        request.advance = &advance;
        let mut lost_result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(session, &request, &mut lost_result) },
            NuxStatus::Ok
        );
        assert_eq!(
            unsafe { nux_screen_session_result_surface_disposition(lost_result) },
            NUX_SURFACE_DISPOSITION_DEVICE_LOST
        );
        assert_eq!(
            unsafe { nux_screen_session_result_output_count(lost_result) },
            0,
            "device loss must be reported before the logical advance commits"
        );
        assert!(!unsafe { nux_screen_session_result_is_dirty(lost_result) });
        unsafe { nux_screen_session_result_free(lost_result) };

        handle
            .token
            .worker
            .call(Some(session_id), move |state| {
                let session = state.session_mut(session_id)?;
                assert_eq!(session.legacy_timestamp_seconds, 0.0);
                assert!(session.injected_device_loss);
                assert!(!session.is_fatal);
                session.injected_device_loss = false;
                Ok::<(), RuntimeFailure>(())
            })
            .expect("worker inspects configured device-loss preflight")
            .expect("device loss leaves the configured session retryable");

        let retry = NuxScreenAdvanceOperation {
            render: 0,
            ..advance
        };
        request.advance = &retry;
        let mut retry_result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(session, &request, &mut retry_result) },
            NuxStatus::Ok
        );
        let runtime_advanced = (0..unsafe { nux_screen_session_result_output_count(retry_result) })
            .map(|index| public_output_at(retry_result, index))
            .find(|output| output.kind == NUX_SCREEN_OUTPUT_KIND_RUNTIME_ADVANCED)
            .expect("the retry performs the first logical advance");
        assert_eq!(runtime_advanced.sequence, 1);
        assert_eq!(runtime_advanced.cycle, 1);

        unsafe {
            nux_screen_session_result_free(retry_result);
            nux_screen_session_free(session);
            nux_experience_context_free(context);
        }
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn signed_scripted_artifact_crosses_public_configured_session_seam_with_isolated_resource_failure()
     {
        with_signed_scripted_apple_import_request(|request| {
            let mut context = ptr::null_mut();
            let mut import_result = ptr::null_mut();
            assert_eq!(
                unsafe {
                    nux_experience_context_create_bound(
                        runtime_binding(),
                        request,
                        &mut context,
                        &mut import_result,
                    )
                },
                NuxStatus::Ok
            );
            assert!(!context.is_null());
            assert_eq!(
                unsafe { nux_operation_result_diagnostic_count(import_result) },
                0
            );
            unsafe { nux_operation_result_free(import_result) };

            let descriptor = configured_descriptor();
            let mut session = ptr::null_mut();
            let mut creation = ptr::null_mut();
            assert_eq!(
                unsafe {
                    nux_screen_session_create_configured(
                        context,
                        &descriptor,
                        &mut session,
                        &mut creation,
                    )
                },
                NuxStatus::Ok
            );
            assert!(!session.is_null());
            assert_eq!(
                unsafe { nux_screen_session_result_status(creation) },
                NuxStatus::Ok
            );
            assert_eq!(
                unsafe { nux_screen_session_result_output_count(creation) },
                2
            );

            let loaded = public_output_at(creation, 0);
            assert_eq!(loaded.phase, NUX_SCREEN_OUTPUT_PHASE_HOST_WORK);
            assert_eq!(loaded.kind, NUX_SCREEN_OUTPUT_KIND_HOST_COMMAND);
            assert_eq!(loaded.sequence, 1);
            assert_eq!(loaded.cycle, 0);
            assert_eq!(copied_byte_view(loaded.name), b"fixture_loaded");
            assert_eq!(loaded.payload.len, 0);
            let loaded_root = public_value_node_at(creation, loaded.payload_root_index);
            assert_eq!(loaded_root.kind, NUX_SCREEN_VALUE_KIND_OBJECT);
            let authenticated = public_value_node_at(
                creation,
                public_object_child(creation, loaded.payload_root_index, b"authenticated"),
            );
            assert_eq!(authenticated.kind, NUX_SCREEN_VALUE_KIND_BOOL);
            assert_eq!(authenticated.bool_value, 1);
            let nested_index = public_object_child(creation, loaded.payload_root_index, b"nested");
            let nested = public_value_node_at(creation, nested_index);
            assert_eq!(nested.kind, NUX_SCREEN_VALUE_KIND_LIST);
            assert_eq!(nested.edge_count, 2);
            let first_nested = public_value_edge_at(creation, nested.first_edge);
            assert!(copied_byte_view(first_nested.key).is_empty());
            let first_nested = public_value_node_at(creation, first_nested.node_index);
            assert_eq!(first_nested.kind, NUX_SCREEN_VALUE_KIND_STRING);
            assert_eq!(copied_byte_view(first_nested.string_value), b"apple");
            let second_edge_index = nested
                .first_edge
                .checked_add(1)
                .expect("fixture list has a second edge");
            let second_nested = public_value_edge_at(creation, second_edge_index);
            let second_nested = public_value_node_at(creation, second_nested.node_index);
            assert_eq!(second_nested.kind, NUX_SCREEN_VALUE_KIND_NUMBER);
            assert_eq!(second_nested.number_value, 14.0);

            let response = public_output_at(creation, 1);
            assert_eq!(response.phase, NUX_SCREEN_OUTPUT_PHASE_HOST_WORK);
            assert_eq!(response.kind, NUX_SCREEN_OUTPUT_KIND_HOST_COMMAND);
            assert_eq!(response.sequence, 2);
            assert_eq!(response.cycle, 0);
            assert_eq!(copied_byte_view(response.name), b"$response_set");
            let field = public_value_node_at(
                creation,
                public_object_child(creation, response.payload_root_index, b"field"),
            );
            assert_eq!(field.kind, NUX_SCREEN_VALUE_KIND_STRING);
            assert_eq!(copied_byte_view(field.string_value), b"welcome");
            let response_value =
                public_object_child(creation, response.payload_root_index, b"value");
            let title = public_value_node_at(
                creation,
                public_object_child(creation, response_value, b"title"),
            );
            assert_eq!(title.kind, NUX_SCREEN_VALUE_KIND_STRING);
            assert_eq!(copied_byte_view(title.string_value), b"Hello from Luau");
            let enabled = public_value_node_at(
                creation,
                public_object_child(creation, response_value, b"enabled"),
            );
            assert_eq!(enabled.kind, NUX_SCREEN_VALUE_KIND_BOOL);
            assert_eq!(enabled.bool_value, 1);
            let count = public_value_node_at(
                creation,
                public_object_child(creation, response_value, b"count"),
            );
            assert_eq!(count.kind, NUX_SCREEN_VALUE_KIND_NUMBER);
            assert_eq!(count.number_value, 14.0);
            unsafe { nux_screen_session_result_free(creation) };

            let mut sibling = ptr::null_mut();
            let mut sibling_creation = ptr::null_mut();
            assert_eq!(
                unsafe {
                    nux_screen_session_create_configured(
                        context,
                        &descriptor,
                        &mut sibling,
                        &mut sibling_creation,
                    )
                },
                NuxStatus::Ok
            );
            assert!(!sibling.is_null());
            assert_eq!(
                unsafe { nux_screen_session_result_status(sibling_creation) },
                NuxStatus::Ok
            );
            assert_eq!(
                unsafe { nux_screen_session_result_output_count(sibling_creation) },
                2
            );
            unsafe { nux_screen_session_result_free(sibling_creation) };

            let overflowing_advance = NuxScreenAdvanceOperation {
                struct_size: size_u32::<NuxScreenAdvanceOperation>(),
                timestamp_seconds: 1.0,
                delta_seconds: 1.0,
                render: 0,
                apple_drawable: ptr::null_mut(),
                completion_context: ptr::null_mut(),
                completion_callback: None,
            };
            let mut overflowing_operation = operation(NUX_SCREEN_SESSION_OPERATION_KIND_ADVANCE);
            overflowing_operation.advance = &overflowing_advance;
            let mut overflow_result = ptr::null_mut();
            assert_eq!(
                unsafe {
                    nux_screen_session_perform(
                        session,
                        &overflowing_operation,
                        &mut overflow_result,
                    )
                },
                NuxStatus::RuntimeError
            );
            assert_session_diagnostic_code(overflow_result, SCRIPT_RESOURCE_DIAGNOSTIC_CODE);
            assert_eq!(
                unsafe { nux_screen_session_result_output_count(overflow_result) },
                0,
                "partial HostWork must not cross the public result seam"
            );
            unsafe { nux_screen_session_result_free(overflow_result) };

            let sibling_advance = NuxScreenAdvanceOperation {
                struct_size: size_u32::<NuxScreenAdvanceOperation>(),
                timestamp_seconds: 0.25,
                delta_seconds: 0.25,
                render: 0,
                apple_drawable: ptr::null_mut(),
                completion_context: ptr::null_mut(),
                completion_callback: None,
            };
            let mut sibling_operation = operation(NUX_SCREEN_SESSION_OPERATION_KIND_ADVANCE);
            sibling_operation.advance = &sibling_advance;
            let mut sibling_result = ptr::null_mut();
            assert_eq!(
                unsafe {
                    nux_screen_session_perform(sibling, &sibling_operation, &mut sibling_result)
                },
                NuxStatus::Ok
            );
            assert_eq!(
                unsafe { nux_screen_session_result_status(sibling_result) },
                NuxStatus::Ok
            );
            let sibling_host_output =
                (0..unsafe { nux_screen_session_result_output_count(sibling_result) })
                    .map(|index| public_output_at(sibling_result, index))
                    .find(|output| output.kind == NUX_SCREEN_OUTPUT_KIND_HOST_COMMAND)
                    .expect("sibling advance emits its host command");
            assert_eq!(sibling_host_output.phase, NUX_SCREEN_OUTPUT_PHASE_HOST_WORK);
            assert_eq!(sibling_host_output.cycle, 1);
            assert_eq!(copied_byte_view(sibling_host_output.name), b"sibling_ok");
            let sibling_delta = public_value_node_at(
                sibling_result,
                public_object_child(
                    sibling_result,
                    sibling_host_output.payload_root_index,
                    b"delta",
                ),
            );
            assert_eq!(sibling_delta.kind, NUX_SCREEN_VALUE_KIND_NUMBER);
            assert_eq!(sibling_delta.number_value, 0.25);

            unsafe {
                nux_screen_session_result_free(sibling_result);
                nux_screen_session_free(sibling);
                nux_screen_session_free(session);
                nux_experience_context_free(context);
            }
        });
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn configured_render_without_a_surface_does_not_advance_or_drain_host_work() {
        with_signed_scripted_apple_import_request(|request| {
            let mut context = ptr::null_mut();
            let mut import_result = ptr::null_mut();
            assert_eq!(
                unsafe {
                    nux_experience_context_create_bound(
                        runtime_binding(),
                        request,
                        &mut context,
                        &mut import_result,
                    )
                },
                NuxStatus::Ok
            );
            unsafe { nux_operation_result_free(import_result) };

            let descriptor = configured_descriptor();
            let mut session = ptr::null_mut();
            let mut creation = ptr::null_mut();
            assert_eq!(
                unsafe {
                    nux_screen_session_create_configured(
                        context,
                        &descriptor,
                        &mut session,
                        &mut creation,
                    )
                },
                NuxStatus::Ok
            );
            assert_eq!(
                unsafe { nux_screen_session_result_output_count(creation) },
                2
            );
            unsafe { nux_screen_session_result_free(creation) };

            let advance = NuxScreenAdvanceOperation {
                struct_size: size_u32::<NuxScreenAdvanceOperation>(),
                timestamp_seconds: 0.25,
                delta_seconds: 0.25,
                render: 1,
                apple_drawable: ptr::null_mut(),
                completion_context: ptr::null_mut(),
                completion_callback: None,
            };
            let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_ADVANCE);
            request.advance = &advance;
            let mut missing_surface_result = ptr::null_mut();
            assert_eq!(
                unsafe {
                    nux_screen_session_perform(session, &request, &mut missing_surface_result)
                },
                NuxStatus::SurfaceError
            );
            unsafe { nux_screen_session_result_free(missing_surface_result) };

            let retry_advance = NuxScreenAdvanceOperation {
                render: 0,
                ..advance
            };
            request.advance = &retry_advance;
            let mut retry_result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_screen_session_perform(session, &request, &mut retry_result) },
                NuxStatus::Ok
            );
            let host_output = (0..unsafe { nux_screen_session_result_output_count(retry_result) })
                .map(|index| public_output_at(retry_result, index))
                .find(|output| output.kind == NUX_SCREEN_OUTPUT_KIND_HOST_COMMAND)
                .expect("the first committed advance emits its host command");
            assert_eq!(host_output.sequence, 4);
            assert_eq!(host_output.cycle, 1);
            assert_eq!(copied_byte_view(host_output.name), b"sibling_ok");

            unsafe {
                nux_screen_session_result_free(retry_result);
                nux_screen_session_free(session);
                nux_experience_context_free(context);
            }
        });
    }

    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    #[test]
    fn configured_surface_preflight_error_does_not_advance_or_drain_host_work() {
        with_signed_scripted_apple_import_request(|request| {
            let mut context = ptr::null_mut();
            let mut import_result = ptr::null_mut();
            assert_eq!(
                unsafe {
                    nux_experience_context_create_bound(
                        runtime_binding(),
                        request,
                        &mut context,
                        &mut import_result,
                    )
                },
                NuxStatus::Ok
            );
            unsafe { nux_operation_result_free(import_result) };

            let descriptor = configured_descriptor();
            let mut session = ptr::null_mut();
            let mut creation = ptr::null_mut();
            assert_eq!(
                unsafe {
                    nux_screen_session_create_configured(
                        context,
                        &descriptor,
                        &mut session,
                        &mut creation,
                    )
                },
                NuxStatus::Ok
            );
            unsafe { nux_screen_session_result_free(creation) };

            let session_handle = unsafe { &*session.cast::<ScreenSessionHandle>() };
            let session_id = session_handle.token.id;
            let surface_id = session_handle
                .token
                .worker
                .call(Some(session_id), move |state| {
                    state.attach_surface(session_id, 8, 8)
                })
                .expect("worker accepts surface attachment")
                .expect("surface attachment succeeds");
            session_handle
                .token
                .worker
                .call(Some(session_id), move |state| {
                    let session = state.session_mut(session_id)?;
                    let attachment = session
                        .attachment
                        .as_mut()
                        .filter(|attachment| attachment.id == surface_id)
                        .ok_or_else(|| RuntimeFailure::surface("test surface is unavailable"))?;
                    attachment.surface.detach();
                    Ok::<(), RuntimeFailure>(())
                })
                .expect("worker accepts preflight fault injection")
                .expect("preflight fault injection succeeds");

            let render_advance = NuxScreenAdvanceOperation {
                struct_size: size_u32::<NuxScreenAdvanceOperation>(),
                timestamp_seconds: 0.25,
                delta_seconds: 0.25,
                render: 1,
                apple_drawable: ptr::null_mut(),
                completion_context: ptr::null_mut(),
                completion_callback: None,
            };
            let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_ADVANCE);
            request.advance = &render_advance;
            let mut preflight_result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_screen_session_perform(session, &request, &mut preflight_result) },
                NuxStatus::SurfaceError
            );
            unsafe { nux_screen_session_result_free(preflight_result) };

            let retry_advance = NuxScreenAdvanceOperation {
                render: 0,
                ..render_advance
            };
            request.advance = &retry_advance;
            let mut retry_result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_screen_session_perform(session, &request, &mut retry_result) },
                NuxStatus::Ok
            );
            let host_output = (0..unsafe { nux_screen_session_result_output_count(retry_result) })
                .map(|index| public_output_at(retry_result, index))
                .find(|output| output.kind == NUX_SCREEN_OUTPUT_KIND_HOST_COMMAND)
                .expect("the first committed advance emits its host command");
            assert_eq!(host_output.sequence, 4);
            assert_eq!(host_output.cycle, 1);
            assert_eq!(copied_byte_view(host_output.name), b"sibling_ok");

            unsafe {
                nux_screen_session_result_free(retry_result);
                nux_screen_session_free(session);
                nux_experience_context_free(context);
            }
        });
    }

    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    #[test]
    fn configured_present_failure_terminalizes_the_committed_session() {
        autoreleasepool(|_| {
            with_signed_scripted_apple_import_request(|request| {
                let mut context = ptr::null_mut();
                let mut import_result = ptr::null_mut();
                assert_eq!(
                    unsafe {
                        nux_experience_context_create_bound(
                            runtime_binding(),
                            request,
                            &mut context,
                            &mut import_result,
                        )
                    },
                    NuxStatus::Ok
                );
                unsafe { nux_operation_result_free(import_result) };

                let descriptor = configured_descriptor();
                let mut session = ptr::null_mut();
                let mut creation = ptr::null_mut();
                assert_eq!(
                    unsafe {
                        nux_screen_session_create_configured(
                            context,
                            &descriptor,
                            &mut session,
                            &mut creation,
                        )
                    },
                    NuxStatus::Ok
                );
                unsafe { nux_screen_session_result_free(creation) };

                let surface_descriptor = NuxAppleSurfaceDescriptor {
                    struct_size: size_u32::<NuxAppleSurfaceDescriptor>(),
                    pixel_width: 8,
                    pixel_height: 8,
                };
                let mut surface = ptr::null_mut();
                let mut surface_result = ptr::null_mut();
                assert_eq!(
                    unsafe {
                        nux_screen_session_attach_apple_surface(
                            session,
                            &surface_descriptor,
                            &mut surface,
                            &mut surface_result,
                        )
                    },
                    NuxStatus::Ok
                );
                unsafe { nux_operation_result_free(surface_result) };

                let skipped_advance = NuxScreenAdvanceOperation {
                    struct_size: size_u32::<NuxScreenAdvanceOperation>(),
                    timestamp_seconds: 0.25,
                    delta_seconds: 0.25,
                    render: 1,
                    apple_drawable: ptr::null_mut(),
                    completion_context: ptr::null_mut(),
                    completion_callback: None,
                };
                let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_ADVANCE);
                request.advance = &skipped_advance;
                let mut skipped_result = ptr::null_mut();
                assert_eq!(
                    unsafe { nux_screen_session_perform(session, &request, &mut skipped_result) },
                    NuxStatus::Ok
                );
                assert_eq!(
                    unsafe { nux_screen_session_result_surface_disposition(skipped_result) },
                    NUX_SURFACE_DISPOSITION_SKIPPED_TIMEOUT
                );
                let skipped_host_output =
                    (0..unsafe { nux_screen_session_result_output_count(skipped_result) })
                        .map(|index| public_output_at(skipped_result, index))
                        .find(|output| output.kind == NUX_SCREEN_OUTPUT_KIND_HOST_COMMAND)
                        .expect("a skipped presentation still returns committed host work");
                assert_eq!(skipped_host_output.sequence, 4);
                assert_eq!(skipped_host_output.cycle, 1);
                assert_eq!(copied_byte_view(skipped_host_output.name), b"sibling_ok");
                unsafe { nux_screen_session_result_free(skipped_result) };

                let mut metal_device = ptr::null_mut();
                let mut device_result = ptr::null_mut();
                assert_eq!(
                    unsafe {
                        nux_apple_surface_copy_metal_device(
                            surface,
                            &mut metal_device,
                            &mut device_result,
                        )
                    },
                    NuxStatus::Ok
                );
                unsafe { nux_operation_result_free(device_result) };
                let metal_device: Retained<ProtocolObject<dyn MTLDevice>> = unsafe {
                    Retained::from_raw(metal_device.cast())
                        .expect("copy_metal_device returns a retained device")
                };
                let layer = CAMetalLayer::new();
                layer.setDevice(Some(&metal_device));
                layer.setPixelFormat(MTLPixelFormat::BGRA8Unorm);
                layer.setFramebufferOnly(true);
                layer.setAllowsNextDrawableTimeout(true);
                layer.setDrawableSize(CGSize::new(4.0, 4.0));
                let drawable = layer
                    .nextDrawable()
                    .expect("configured CAMetalLayer provides a wrong-size drawable");
                let drawable_pointer = Retained::as_ptr(&drawable).cast_mut().cast::<c_void>();

                let render_advance = NuxScreenAdvanceOperation {
                    struct_size: size_u32::<NuxScreenAdvanceOperation>(),
                    timestamp_seconds: 0.5,
                    delta_seconds: 0.25,
                    render: 1,
                    apple_drawable: drawable_pointer,
                    completion_context: ptr::null_mut(),
                    completion_callback: None,
                };
                request.advance = &render_advance;
                let mut present_result = ptr::null_mut();
                assert_eq!(
                    unsafe { nux_screen_session_perform(session, &request, &mut present_result) },
                    NuxStatus::SurfaceError
                );
                unsafe { nux_screen_session_result_free(present_result) };

                let session_handle = unsafe { &*session.cast::<ScreenSessionHandle>() };
                let session_id = session_handle.token.id;
                let (is_fatal, fatal_diagnostic) = session_handle
                    .token
                    .worker
                    .call(Some(session_id), move |state| {
                        state
                            .session(session_id)
                            .map(|session| (session.is_fatal, session.fatal_diagnostic.clone()))
                    })
                    .expect("worker reports terminal state")
                    .expect("configured session remains allocated");
                assert!(is_fatal);
                let fatal_diagnostic = fatal_diagnostic.expect("terminal reason is retained");
                assert!(fatal_diagnostic.contains("committed advance failed during presentation"));
                assert!(fatal_diagnostic.contains("texture is 4x4, expected 8x8"));

                let retry_advance = NuxScreenAdvanceOperation {
                    render: 0,
                    apple_drawable: ptr::null_mut(),
                    timestamp_seconds: 0.75,
                    ..render_advance
                };
                request.advance = &retry_advance;
                let mut retry_result = ptr::null_mut();
                assert_eq!(
                    unsafe { nux_screen_session_perform(session, &request, &mut retry_result) },
                    NuxStatus::RuntimeError
                );
                assert_eq!(
                    unsafe { nux_screen_session_result_output_count(retry_result) },
                    0
                );
                let mut diagnostic = NuxDiagnosticView::default();
                assert_eq!(
                    unsafe {
                        nux_screen_session_result_diagnostic_at(retry_result, 0, &mut diagnostic)
                    },
                    NuxStatus::Ok
                );
                assert_eq!(
                    copied_byte_view(diagnostic.message),
                    fatal_diagnostic.as_bytes()
                );

                unsafe {
                    nux_screen_session_result_free(retry_result);
                    nux_apple_surface_free(surface);
                    nux_screen_session_free(session);
                    nux_experience_context_free(context);
                }
            });
        });
    }

    #[test]
    fn player_metadata_requires_consistent_kind_selection_and_index() {
        let mut result = ScreenSessionResultHandle::empty_success();
        result.player_metadata = Some(OwnedPlayerMetadata {
            kind: NUX_SCREEN_PLAYER_KIND_STATE_MACHINE,
            selection: NUX_SCREEN_PLAYER_SELECTION_EXPLICIT_STATE_MACHINE,
            player_index: Some(0),
            artboard_name: b"screen".to_vec(),
            player_name: b"machine".to_vec(),
            min_x: 0.0,
            min_y: 0.0,
            max_x: 100.0,
            max_y: 100.0,
        });
        assert_eq!(result.validate(), Ok(()));

        let metadata = result
            .player_metadata
            .as_mut()
            .expect("metadata is present");
        metadata.selection = NUX_SCREEN_PLAYER_SELECTION_STATIC;
        assert_eq!(result.validate(), Err(NuxStatus::RuntimeError));

        let metadata = result
            .player_metadata
            .as_mut()
            .expect("metadata is present");
        metadata.kind = NUX_SCREEN_PLAYER_KIND_STATIC;
        assert_eq!(result.validate(), Err(NuxStatus::RuntimeError));
        result
            .player_metadata
            .as_mut()
            .expect("metadata is present")
            .player_index = None;
        assert_eq!(result.validate(), Ok(()));
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn configured_player_selection_keeps_named_state_machines_and_linear_animations() {
        const FIXTURE: &[u8] = include_bytes!("../../../fixtures/animation/smi_test.riv");
        let worker = match RuntimeWorker::spawn(FIXTURE.to_vec()) {
            Ok(worker) => worker,
            Err(_) => panic!("import player fixture"),
        };
        let context = Box::into_raw(Box::new(ExperienceRuntimeContextHandle { worker }))
            .cast::<NuxExperienceContext>();

        let mut descriptor = configured_descriptor();
        descriptor.artboard_name = bytes(b"artboard to nest");
        descriptor.player_kind = NUX_SCREEN_PLAYER_SELECTOR_KIND_STATE_MACHINE;
        descriptor.player_name = bytes(b"State Machine 1");
        let mut session = ptr::null_mut();
        let mut result = ptr::null_mut();
        assert_eq!(
            unsafe {
                nux_screen_session_create_configured(
                    context,
                    &descriptor,
                    &mut session,
                    &mut result,
                )
            },
            NuxStatus::Ok
        );
        let mut metadata: NuxScreenPlayerMetadataView = unsafe { std::mem::zeroed() };
        metadata.struct_size = size_u32::<NuxScreenPlayerMetadataView>();
        assert_eq!(
            unsafe { nux_screen_session_result_player_metadata(result, &mut metadata) },
            NuxStatus::Ok
        );
        assert_eq!(metadata.kind, NUX_SCREEN_PLAYER_KIND_STATE_MACHINE);
        assert_eq!(
            metadata.selection,
            NUX_SCREEN_PLAYER_SELECTION_EXPLICIT_STATE_MACHINE
        );
        unsafe {
            nux_screen_session_result_free(result);
            nux_screen_session_free(session);
        }

        descriptor.player_kind = NUX_SCREEN_PLAYER_SELECTOR_KIND_LINEAR_ANIMATION;
        descriptor.player_name = bytes(b"Timeline 1");
        session = ptr::null_mut();
        result = ptr::null_mut();
        assert_eq!(
            unsafe {
                nux_screen_session_create_configured(
                    context,
                    &descriptor,
                    &mut session,
                    &mut result,
                )
            },
            NuxStatus::Ok
        );
        metadata.struct_size = size_u32::<NuxScreenPlayerMetadataView>();
        assert_eq!(
            unsafe { nux_screen_session_result_player_metadata(result, &mut metadata) },
            NuxStatus::Ok
        );
        assert_eq!(metadata.kind, NUX_SCREEN_PLAYER_KIND_LINEAR_ANIMATION);
        assert_eq!(
            metadata.selection,
            NUX_SCREEN_PLAYER_SELECTION_EXPLICIT_LINEAR_ANIMATION
        );
        assert_eq!(copied_byte_view(metadata.player_name), b"Timeline 1");
        unsafe {
            nux_screen_session_result_free(result);
            nux_screen_session_free(session);
        }

        descriptor.player_name = bytes(b"missing");
        for player_kind in [
            NUX_SCREEN_PLAYER_SELECTOR_KIND_STATE_MACHINE,
            NUX_SCREEN_PLAYER_SELECTOR_KIND_LINEAR_ANIMATION,
        ] {
            descriptor.player_kind = player_kind;
            session = ptr::null_mut();
            result = ptr::null_mut();
            assert_eq!(
                unsafe {
                    nux_screen_session_create_configured(
                        context,
                        &descriptor,
                        &mut session,
                        &mut result,
                    )
                },
                NuxStatus::NotFound
            );
            assert!(session.is_null());
            assert_eq!(
                unsafe { nux_screen_session_result_status(result) },
                NuxStatus::NotFound
            );
            unsafe { nux_screen_session_result_free(result) };
        }

        unsafe { nux_experience_context_free(context) };
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn configured_create_bootstrap_and_query_round_trip_use_the_real_flow_session() {
        const FIXTURE: &[u8] = include_bytes!("../../../fixtures/animation/smi_test.riv");
        let worker = match RuntimeWorker::spawn(FIXTURE.to_vec()) {
            Ok(worker) => worker,
            Err(_) => panic!("import fixture"),
        };
        let context = Box::into_raw(Box::new(ExperienceRuntimeContextHandle { worker }))
            .cast::<NuxExperienceContext>();
        let mut descriptor = configured_descriptor();
        descriptor.artboard_name = bytes(b"artboard to nest");
        descriptor.player_name = bytes(b"State Machine 1");
        descriptor.player_kind = NUX_SCREEN_PLAYER_SELECTOR_KIND_STATE_MACHINE;
        let mut session = ptr::null_mut();
        let mut create_result = ptr::null_mut();
        assert_eq!(
            unsafe {
                nux_screen_session_create_configured(
                    context,
                    &descriptor,
                    &mut session,
                    &mut create_result,
                )
            },
            NuxStatus::Ok
        );
        assert!(!session.is_null());
        assert_eq!(
            unsafe { nux_screen_session_result_status(create_result) },
            NuxStatus::Ok
        );
        let mut metadata: NuxScreenPlayerMetadataView = unsafe { std::mem::zeroed() };
        metadata.struct_size = size_u32::<NuxScreenPlayerMetadataView>();
        assert_eq!(
            unsafe { nux_screen_session_result_player_metadata(create_result, &mut metadata) },
            NuxStatus::Ok
        );
        assert_eq!(metadata.kind, NUX_SCREEN_PLAYER_KIND_STATE_MACHINE);
        assert_eq!(
            metadata.selection,
            NUX_SCREEN_PLAYER_SELECTION_EXPLICIT_STATE_MACHINE
        );
        assert_ne!(metadata.player_index, u32::MAX);
        assert!(unsafe { nux_screen_session_result_has_values(create_result) });
        assert!(unsafe { nux_screen_session_result_has_catalog(create_result) });
        assert!(!unsafe { nux_screen_session_result_has_player_inputs(create_result) });
        assert_eq!(
            unsafe { nux_screen_session_result_output_count(create_result) },
            0
        );
        unsafe { nux_screen_session_result_free(create_result) };

        let queries = [
            NuxScreenQuery {
                struct_size: size_u32::<NuxScreenQuery>(),
                kind: NUX_SCREEN_QUERY_KIND_PLAYER_INPUTS,
            },
            NuxScreenQuery {
                struct_size: size_u32::<NuxScreenQuery>(),
                kind: NUX_SCREEN_QUERY_KIND_BOOTSTRAP,
            },
        ];
        let query_batch = NuxScreenQueryBatch {
            struct_size: size_u32::<NuxScreenQueryBatch>(),
            queries: queries.as_ptr(),
            query_count: queries.len() as u64,
        };
        let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_QUERY);
        request.query_batch = &query_batch;
        let mut query_result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(session, &request, &mut query_result) },
            NuxStatus::Ok
        );
        assert_eq!(
            unsafe { nux_screen_session_result_status(query_result) },
            NuxStatus::Ok
        );
        metadata.struct_size = size_u32::<NuxScreenPlayerMetadataView>();
        assert_eq!(
            unsafe { nux_screen_session_result_player_metadata(query_result, &mut metadata) },
            NuxStatus::Ok
        );
        assert_eq!(metadata.kind, NUX_SCREEN_PLAYER_KIND_STATE_MACHINE);
        assert!(unsafe { nux_screen_session_result_has_values(query_result) });
        assert!(unsafe { nux_screen_session_result_has_catalog(query_result) });
        assert!(unsafe { nux_screen_session_result_has_player_inputs(query_result) });
        assert!(unsafe { nux_screen_session_result_player_input_count(query_result) } >= 3);
        unsafe { nux_screen_session_result_free(query_result) };

        let query_player_inputs = || {
            let query = NuxScreenQuery {
                struct_size: size_u32::<NuxScreenQuery>(),
                kind: NUX_SCREEN_QUERY_KIND_PLAYER_INPUTS,
            };
            let query_batch = NuxScreenQueryBatch {
                struct_size: size_u32::<NuxScreenQueryBatch>(),
                queries: &query,
                query_count: 1,
            };
            let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_QUERY);
            request.query_batch = &query_batch;
            let mut result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_screen_session_perform(session, &request, &mut result) },
                NuxStatus::Ok
            );
            result
        };
        let bool_input_value = |result: *mut NuxScreenSessionResult| {
            let input_count = unsafe { nux_screen_session_result_player_input_count(result) };
            assert!(input_count >= 3);
            for index in 0..input_count {
                let mut input: NuxScreenPlayerInputView = unsafe { std::mem::zeroed() };
                input.struct_size = size_u32::<NuxScreenPlayerInputView>();
                assert_eq!(
                    unsafe { nux_screen_session_result_player_input_at(result, index, &mut input) },
                    NuxStatus::Ok
                );
                let name =
                    unsafe { slice::from_raw_parts(input.name.data, input.name.len as usize) };
                if name == b"bool" {
                    assert_eq!(input.kind, NUX_SCREEN_PLAYER_INPUT_KIND_BOOL);
                    let mut node: NuxScreenValueNode = unsafe { std::mem::zeroed() };
                    node.struct_size = size_u32::<NuxScreenValueNode>();
                    assert_eq!(
                        unsafe {
                            nux_screen_session_result_value_node_at(
                                result,
                                u64::from(input.value_root_index),
                                &mut node,
                            )
                        },
                        NuxStatus::Ok
                    );
                    assert_eq!(node.kind, NUX_SCREEN_VALUE_KIND_BOOL);
                    return node.bool_value == 1;
                }
            }
            panic!("fixture bool input is missing")
        };

        let input_result = query_player_inputs();
        assert!(!bool_input_value(input_result));
        unsafe { nux_screen_session_result_free(input_result) };

        let mut bool_value = null_node(NUX_SCREEN_VALUE_KIND_BOOL);
        bool_value.bool_value = 1;
        let value_arena = NuxScreenValueArena {
            struct_size: size_u32::<NuxScreenValueArena>(),
            nodes: &bool_value,
            node_count: 1,
            edges: ptr::null(),
            edge_count: 0,
        };
        let zero_reference = NuxScreenInstanceReference {
            kind: 0,
            local_id: 0,
            instance_id: 0,
        };
        let input_mutation = NuxScreenStateMutation {
            struct_size: size_u32::<NuxScreenStateMutation>(),
            kind: NUX_SCREEN_STATE_MUTATION_KIND_SET_INPUT_BOOL,
            instance: zero_reference,
            item: zero_reference,
            path: NuxByteView::default(),
            input_name: bytes(b"bool"),
            value_root_index: 0,
            index: 0,
            other_index: 0,
        };
        let state_batch = NuxScreenStateBatch {
            struct_size: size_u32::<NuxScreenStateBatch>(),
            has_host_mutation_id: 1,
            host_mutation_id: 0,
            value_arena: &value_arena,
            new_instances: ptr::null(),
            new_instance_count: 0,
            mutations: &input_mutation,
            mutation_count: 1,
        };
        let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_STATE_BATCH);
        request.state_batch = &state_batch;
        let mut state_result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(session, &request, &mut state_result) },
            NuxStatus::Ok
        );
        assert_eq!(
            unsafe { nux_screen_session_result_output_count(state_result) },
            1
        );
        let mut output: NuxScreenOutputView = unsafe { std::mem::zeroed() };
        output.struct_size = size_u32::<NuxScreenOutputView>();
        assert_eq!(
            unsafe { nux_screen_session_result_output_at(state_result, 0, &mut output) },
            NuxStatus::Ok
        );
        assert_eq!(output.kind, NUX_SCREEN_OUTPUT_KIND_STATE_CHANGE);
        assert_eq!(output.has_origin_mutation_id, 1);
        assert_eq!(output.origin_mutation_id, 0);
        unsafe { nux_screen_session_result_free(state_result) };

        let input_result = query_player_inputs();
        assert!(bool_input_value(input_result));
        unsafe { nux_screen_session_result_free(input_result) };

        let advance = NuxScreenAdvanceOperation {
            struct_size: size_u32::<NuxScreenAdvanceOperation>(),
            timestamp_seconds: 0.0,
            delta_seconds: 0.0,
            render: 0,
            apple_drawable: ptr::null_mut(),
            completion_context: ptr::null_mut(),
            completion_callback: None,
        };
        let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_ADVANCE);
        request.advance = &advance;
        let mut advance_result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(session, &request, &mut advance_result) },
            NuxStatus::Ok
        );
        assert_eq!(
            unsafe { nux_screen_session_result_status(advance_result) },
            NuxStatus::Ok
        );
        assert!(unsafe { nux_screen_session_result_output_count(advance_result) } >= 1);
        unsafe { nux_screen_session_result_free(advance_result) };

        let pointer = NuxScreenPointerEvent {
            struct_size: size_u32::<NuxScreenPointerEvent>(),
            kind: NUX_SCREEN_POINTER_EVENT_KIND_DOWN,
            pointer_id: 1,
            x: 0.0,
            y: 0.0,
            timestamp_seconds: 42.25,
        };
        let pointer_batch = NuxScreenPointerBatch {
            struct_size: size_u32::<NuxScreenPointerBatch>(),
            events: &pointer,
            event_count: 1,
        };
        let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_POINTER_BATCH);
        request.pointer_batch = &pointer_batch;
        let mut pointer_result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(session, &request, &mut pointer_result) },
            NuxStatus::Ok
        );
        assert_eq!(
            unsafe { nux_screen_session_result_status(pointer_result) },
            NuxStatus::Ok
        );
        unsafe { nux_screen_session_result_free(pointer_result) };

        let legacy_advance = NuxFrameOperation {
            struct_size: size_u32::<NuxFrameOperation>(),
            elapsed_seconds: 0.25,
            render: false,
            apple_drawable: ptr::null_mut(),
            completion_context: ptr::null_mut(),
            completion_callback: None,
        };
        let mut legacy_result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_advance(session, &legacy_advance, &mut legacy_result) },
            NuxStatus::Ok
        );
        unsafe { nux_operation_result_free(legacy_result) };

        let mixed_advance = NuxScreenAdvanceOperation {
            timestamp_seconds: 0.5,
            delta_seconds: 0.25,
            ..advance
        };
        let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_ADVANCE);
        request.advance = &mixed_advance;
        let mut mixed_result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(session, &request, &mut mixed_result) },
            NuxStatus::Ok
        );
        unsafe { nux_screen_session_result_free(mixed_result) };

        legacy_result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_advance(session, &legacy_advance, &mut legacy_result) },
            NuxStatus::Ok
        );
        unsafe { nux_operation_result_free(legacy_result) };

        unsafe {
            nux_screen_session_free(session);
            nux_experience_context_free(context);
        }
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn configured_session_round_trips_list_index_values_as_their_own_abi_kind() {
        let fixture = flow_fixture("component_list_2.riv");
        let worker = match RuntimeWorker::spawn(fixture) {
            Ok(worker) => worker,
            Err(_) => panic!("import fixture"),
        };
        let context = Box::into_raw(Box::new(ExperienceRuntimeContextHandle { worker }))
            .cast::<NuxExperienceContext>();
        let mut descriptor = configured_descriptor();
        descriptor.artboard_name = bytes(b"Item");
        let mut session = ptr::null_mut();
        let mut create_result = ptr::null_mut();
        assert_eq!(
            unsafe {
                nux_screen_session_create_configured(
                    context,
                    &descriptor,
                    &mut session,
                    &mut create_result,
                )
            },
            NuxStatus::Ok
        );

        let root_id = (0..unsafe { nux_screen_session_result_instance_count(create_result) })
            .find_map(|index| {
                let mut instance: NuxScreenInstanceView = unsafe { std::mem::zeroed() };
                instance.struct_size = size_u32::<NuxScreenInstanceView>();
                assert_eq!(
                    unsafe {
                        nux_screen_session_result_instance_at(create_result, index, &mut instance)
                    },
                    NuxStatus::Ok
                );
                (instance.is_root == 1).then_some(instance.instance_id)
            })
            .expect("root instance id");
        let initial = (0..unsafe { nux_screen_session_result_value_node_count(create_result) })
            .find_map(|index| {
                let mut node = null_node(NUX_SCREEN_VALUE_KIND_NULL);
                assert_eq!(
                    unsafe {
                        nux_screen_session_result_value_node_at(create_result, index, &mut node)
                    },
                    NuxStatus::Ok
                );
                (node.kind == NUX_SCREEN_VALUE_KIND_LIST_INDEX).then_some(node.identity_value)
            });
        assert_eq!(initial, Some(0));
        unsafe { nux_screen_session_result_free(create_result) };

        let mut value = null_node(NUX_SCREEN_VALUE_KIND_LIST_INDEX);
        value.identity_value = 7;
        let arena = NuxScreenValueArena {
            struct_size: size_u32::<NuxScreenValueArena>(),
            nodes: &value,
            node_count: 1,
            edges: ptr::null(),
            edge_count: 0,
        };
        let zero = NuxScreenInstanceReference {
            kind: 0,
            local_id: 0,
            instance_id: 0,
        };
        let mutation = NuxScreenStateMutation {
            struct_size: size_u32::<NuxScreenStateMutation>(),
            kind: NUX_SCREEN_STATE_MUTATION_KIND_SET,
            instance: NuxScreenInstanceReference {
                kind: NUX_SCREEN_INSTANCE_REFERENCE_KIND_EXISTING,
                local_id: 0,
                instance_id: root_id,
            },
            item: zero,
            path: bytes(b"List Index"),
            input_name: NuxByteView::default(),
            value_root_index: 0,
            index: 0,
            other_index: 0,
        };
        let batch = NuxScreenStateBatch {
            struct_size: size_u32::<NuxScreenStateBatch>(),
            has_host_mutation_id: 1,
            host_mutation_id: 41,
            value_arena: &arena,
            new_instances: ptr::null(),
            new_instance_count: 0,
            mutations: &mutation,
            mutation_count: 1,
        };
        let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_STATE_BATCH);
        request.state_batch = &batch;
        let mut result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(session, &request, &mut result) },
            NuxStatus::Ok
        );
        assert_eq!(unsafe { nux_screen_session_result_output_count(result) }, 1);
        let mut output: NuxScreenOutputView = unsafe { std::mem::zeroed() };
        output.struct_size = size_u32::<NuxScreenOutputView>();
        assert_eq!(
            unsafe { nux_screen_session_result_output_at(result, 0, &mut output) },
            NuxStatus::Ok
        );
        let mut echoed = null_node(NUX_SCREEN_VALUE_KIND_NULL);
        assert_eq!(
            unsafe {
                nux_screen_session_result_value_node_at(
                    result,
                    u64::from(output.payload_root_index),
                    &mut echoed,
                )
            },
            NuxStatus::Ok
        );
        assert_eq!(echoed.kind, NUX_SCREEN_VALUE_KIND_LIST_INDEX);
        assert_eq!(echoed.identity_value, 7);

        unsafe {
            nux_screen_session_result_free(result);
            nux_screen_session_free(session);
            nux_experience_context_free(context);
        }
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn configured_catalog_exposes_enum_labels_and_referenced_schema_ids() {
        fn view_bytes(view: NuxByteView) -> Vec<u8> {
            if view.len == 0 {
                Vec::new()
            } else {
                unsafe { slice::from_raw_parts(view.data, view.len as usize) }.to_vec()
            }
        }

        fn create(
            fixture_name: &str,
            artboard_name: &[u8],
        ) -> (
            *mut NuxExperienceContext,
            *mut NuxScreenSession,
            *mut NuxScreenSessionResult,
        ) {
            let fixture = flow_fixture(fixture_name);
            let worker = match RuntimeWorker::spawn(fixture) {
                Ok(worker) => worker,
                Err(_) => panic!("import catalog fixture"),
            };
            let context = Box::into_raw(Box::new(ExperienceRuntimeContextHandle { worker }))
                .cast::<NuxExperienceContext>();
            let mut descriptor = configured_descriptor();
            descriptor.artboard_name = bytes(artboard_name);
            let mut session = ptr::null_mut();
            let mut result = ptr::null_mut();
            let status = unsafe {
                nux_screen_session_create_configured(
                    context,
                    &descriptor,
                    &mut session,
                    &mut result,
                )
            };
            assert_eq!(status, NuxStatus::Ok, "{}", unsafe {
                session_result_message(result)
            });
            (context, session, result)
        }

        let (enum_context, enum_session, enum_result) =
            create("data_binding_test.riv", b"artboard-5");
        let state = (0..unsafe { nux_screen_session_result_schema_property_count(enum_result) })
            .find_map(|index| {
                let mut property: NuxScreenSchemaPropertyView = unsafe { std::mem::zeroed() };
                property.struct_size = size_u32::<NuxScreenSchemaPropertyView>();
                assert_eq!(
                    unsafe {
                        nux_screen_session_result_schema_property_at(
                            enum_result,
                            index,
                            &mut property,
                        )
                    },
                    NuxStatus::Ok
                );
                (view_bytes(property.name) == b"state").then_some(property)
            })
            .expect("state schema property");
        assert_eq!(state.kind, NUX_SCREEN_SCHEMA_PROPERTY_KIND_ENUM);
        assert!(view_bytes(state.referenced_schema_id).is_empty());
        assert_eq!(state.enum_label_count, 3);
        let labels = (0..state.enum_label_count)
            .map(|offset| {
                let mut label: NuxScreenEnumLabelView = unsafe { std::mem::zeroed() };
                label.struct_size = size_u32::<NuxScreenEnumLabelView>();
                assert_eq!(
                    unsafe {
                        nux_screen_session_result_enum_label_at(
                            enum_result,
                            u64::from(state.first_enum_label + offset),
                            &mut label,
                        )
                    },
                    NuxStatus::Ok
                );
                assert_eq!(label.value, offset);
                view_bytes(label.label)
            })
            .collect::<Vec<_>>();
        assert_eq!(
            labels,
            [
                b"state-red".to_vec(),
                b"state-green".to_vec(),
                b"state-blue".to_vec()
            ]
        );
        unsafe {
            nux_screen_session_result_free(enum_result);
            nux_screen_session_free(enum_session);
            nux_experience_context_free(enum_context);
        }

        let (reference_context, reference_session, reference_result) =
            create("replace_view_model.riv", b"Artboard");
        let child =
            (0..unsafe { nux_screen_session_result_schema_property_count(reference_result) })
                .find_map(|index| {
                    let mut property: NuxScreenSchemaPropertyView = unsafe { std::mem::zeroed() };
                    property.struct_size = size_u32::<NuxScreenSchemaPropertyView>();
                    assert_eq!(
                        unsafe {
                            nux_screen_session_result_schema_property_at(
                                reference_result,
                                index,
                                &mut property,
                            )
                        },
                        NuxStatus::Ok
                    );
                    (view_bytes(property.schema_id) == b"Main"
                        && view_bytes(property.name) == b"child")
                        .then_some(property)
                })
                .expect("child schema property");
        assert_eq!(child.kind, NUX_SCREEN_SCHEMA_PROPERTY_KIND_VIEW_MODEL);
        assert_eq!(view_bytes(child.referenced_schema_id), b"Child");
        assert_eq!(child.enum_label_count, 0);
        unsafe {
            nux_screen_session_result_free(reference_result);
            nux_screen_session_free(reference_session);
            nux_experience_context_free(reference_context);
        }
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn configured_session_replaces_a_nested_view_model_with_a_shared_instance() {
        let fixture = flow_fixture("replace_view_model.riv");
        let worker = match RuntimeWorker::spawn(fixture) {
            Ok(worker) => worker,
            Err(_) => panic!("import replacement fixture"),
        };
        let context = Box::into_raw(Box::new(ExperienceRuntimeContextHandle { worker }))
            .cast::<NuxExperienceContext>();
        let mut descriptor = configured_descriptor();
        descriptor.artboard_name = bytes(b"Artboard");
        let mut session = ptr::null_mut();
        let mut create_result = ptr::null_mut();
        let status = unsafe {
            nux_screen_session_create_configured(
                context,
                &descriptor,
                &mut session,
                &mut create_result,
            )
        };
        assert_eq!(status, NuxStatus::Ok, "{}", unsafe {
            session_result_message(create_result)
        });
        let root_id = (0..unsafe { nux_screen_session_result_instance_count(create_result) })
            .find_map(|index| {
                let mut instance: NuxScreenInstanceView = unsafe { std::mem::zeroed() };
                instance.struct_size = size_u32::<NuxScreenInstanceView>();
                assert_eq!(
                    unsafe {
                        nux_screen_session_result_instance_at(create_result, index, &mut instance)
                    },
                    NuxStatus::Ok
                );
                (instance.is_root == 1).then_some(instance.instance_id)
            })
            .expect("root instance");
        unsafe { nux_screen_session_result_free(create_result) };

        let new_instance = NuxScreenNewInstance {
            struct_size: size_u32::<NuxScreenNewInstance>(),
            local_id: 1,
            schema_name: bytes(b"Child"),
            authored_instance_name: bytes(b"child-2"),
        };
        let mutation = NuxScreenStateMutation {
            struct_size: size_u32::<NuxScreenStateMutation>(),
            kind: NUX_SCREEN_STATE_MUTATION_KIND_SET_VIEW_MODEL,
            instance: NuxScreenInstanceReference {
                kind: NUX_SCREEN_INSTANCE_REFERENCE_KIND_EXISTING,
                local_id: 0,
                instance_id: root_id,
            },
            item: NuxScreenInstanceReference {
                kind: NUX_SCREEN_INSTANCE_REFERENCE_KIND_NEW,
                local_id: 1,
                instance_id: 0,
            },
            path: bytes(b"child"),
            input_name: NuxByteView::default(),
            value_root_index: NO_VALUE_ROOT,
            index: 0,
            other_index: 0,
        };
        let batch = NuxScreenStateBatch {
            struct_size: size_u32::<NuxScreenStateBatch>(),
            has_host_mutation_id: 0,
            host_mutation_id: 0,
            value_arena: ptr::null(),
            new_instances: &new_instance,
            new_instance_count: 1,
            mutations: &mutation,
            mutation_count: 1,
        };
        let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_STATE_BATCH);
        request.state_batch = &batch;
        let mut batch_result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(session, &request, &mut batch_result) },
            NuxStatus::Ok
        );
        let mut created: NuxScreenCreatedInstanceView = unsafe { std::mem::zeroed() };
        created.struct_size = size_u32::<NuxScreenCreatedInstanceView>();
        assert_eq!(
            unsafe { nux_screen_session_result_created_instance_at(batch_result, 0, &mut created) },
            NuxStatus::Ok
        );
        let child_id = created.instance_id;
        assert_eq!(
            unsafe { nux_screen_session_result_output_count(batch_result) },
            1
        );
        assert!(unsafe { nux_screen_session_result_has_values(batch_result) });
        assert!(unsafe { nux_screen_session_result_value_root_count(batch_result) } >= 2);
        let mut output: NuxScreenOutputView = unsafe { std::mem::zeroed() };
        output.struct_size = size_u32::<NuxScreenOutputView>();
        assert_eq!(
            unsafe { nux_screen_session_result_output_at(batch_result, 0, &mut output) },
            NuxStatus::Ok
        );
        assert_eq!(output.kind, NUX_SCREEN_OUTPUT_KIND_VIEW_MODEL_CHANGE);
        assert_ne!(output.payload_root_index, NO_VALUE_ROOT);
        let mut reference = null_node(NUX_SCREEN_VALUE_KIND_NULL);
        assert_eq!(
            unsafe {
                nux_screen_session_result_value_node_at(
                    batch_result,
                    u64::from(output.payload_root_index),
                    &mut reference,
                )
            },
            NuxStatus::Ok
        );
        assert_eq!(reference.kind, NUX_SCREEN_VALUE_KIND_VIEW_MODEL);
        assert_eq!(reference.has_instance_id, 1);
        assert_eq!(reference.instance_id, child_id);
        assert_eq!(reference.edge_count, 0);
        assert_eq!(
            unsafe {
                slice::from_raw_parts(reference.schema_id.data, reference.schema_id.len as usize)
            },
            b"Child"
        );
        unsafe { nux_screen_session_result_free(batch_result) };

        let query = NuxScreenQuery {
            struct_size: size_u32::<NuxScreenQuery>(),
            kind: NUX_SCREEN_QUERY_KIND_VALUES,
        };
        let query_batch = NuxScreenQueryBatch {
            struct_size: size_u32::<NuxScreenQueryBatch>(),
            queries: &query,
            query_count: 1,
        };
        let mut request = operation(NUX_SCREEN_SESSION_OPERATION_KIND_QUERY);
        request.query_batch = &query_batch;
        let mut values = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_perform(session, &request, &mut values) },
            NuxStatus::Ok
        );
        let mut root_node_index = None;
        let mut child_node_index = None;
        for index in 0..unsafe { nux_screen_session_result_value_root_count(values) } {
            let mut root: NuxScreenValueRootView = unsafe { std::mem::zeroed() };
            root.struct_size = size_u32::<NuxScreenValueRootView>();
            assert_eq!(
                unsafe { nux_screen_session_result_value_root_at(values, index, &mut root) },
                NuxStatus::Ok
            );
            if root.instance_id == root_id {
                root_node_index = Some(root.value_root_index);
            } else if root.instance_id == child_id {
                child_node_index = Some(root.value_root_index);
            }
        }
        let root_node_index = root_node_index.expect("owner value root");
        let child_node_index = child_node_index.expect("child value root");
        let mut root_node = null_node(NUX_SCREEN_VALUE_KIND_NULL);
        assert_eq!(
            unsafe {
                nux_screen_session_result_value_node_at(
                    values,
                    u64::from(root_node_index),
                    &mut root_node,
                )
            },
            NuxStatus::Ok
        );
        let linked_child = (0..root_node.edge_count).find_map(|offset| {
            let mut edge: NuxScreenValueEdge = unsafe { std::mem::zeroed() };
            edge.struct_size = size_u32::<NuxScreenValueEdge>();
            assert_eq!(
                unsafe {
                    nux_screen_session_result_value_edge_at(
                        values,
                        u64::from(root_node.first_edge + offset),
                        &mut edge,
                    )
                },
                NuxStatus::Ok
            );
            let key = unsafe { slice::from_raw_parts(edge.key.data, edge.key.len as usize) };
            (key == b"child").then_some(edge.node_index)
        });
        assert_eq!(linked_child, Some(child_node_index));

        unsafe {
            nux_screen_session_result_free(values);
            nux_screen_session_free(session);
            nux_experience_context_free(context);
        }
    }

    #[test]
    fn every_flow_session_export_has_a_panic_firewall() {
        let source = include_str!("session.rs");
        let mut checked = 0usize;
        for prefix in ["pub unsafe extern \"C\" fn ", "pub extern \"C\" fn "] {
            for (index, _) in source.match_indices(prefix) {
                let rest = &source[index..];
                let body_start = rest.find('{').expect("extern function body");
                let body = &rest[body_start + 1..];
                let first_statement = body.trim_start();
                assert!(
                    first_statement.starts_with("ffi_guard(")
                        || first_statement.starts_with("ffi_guard_with_session_result("),
                    "flow-session export is missing its panic firewall: {}",
                    rest.lines().next().unwrap_or_default()
                );
                checked += 1;
            }
        }
        assert!(checked >= 20);
    }
}
