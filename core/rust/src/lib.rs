//! B1 trusted core: the causal ledger, the authority/persistence gate, and P/E anomaly detection.
//!
//! Rust owns this because it is the component that decides whether a lasting state transition may
//! occur and whether recorded history has been altered. It has no dependencies beyond the standard
//! library — including its own SHA-256 and B1-CANON-1 codec — so its supply chain is as small as
//! the guarantees it is asked to make.

pub mod authority;
pub mod canon;
pub mod ledger;
pub mod schema;
pub mod sha256;

pub use authority::{check_at_effect_time, Envelope, GateDecision, GateState, Policy, ProposedEffect};
pub use canon::{b1c1, canonicalize, digest_text, digest_value, parse, B1Error, Json};
pub use schema::{validate as validate_contract, Violation};
pub use ledger::{
    Action, ChainError, EffectClass, Ledger, ObservedEffect, Origin, Outcome, Postcondition,
    Receipt, Record, Validity,
};
