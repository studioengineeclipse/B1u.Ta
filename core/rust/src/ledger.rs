//! The causal ledger: append-only, hash-chained, tamper-evident.
//! Normative: SPEC/30-causal-ledger.md.
//!
//! The record shape is the point. Receipt, observed effect and objective postcondition are three
//! separate optional fields, so a record where the executor claimed success and nothing ever looked
//! is structurally distinguishable from one where the objective was verified. There is deliberately
//! no code path from "receipt present" to `Outcome::Verified`.

use crate::canon::{b1c1, digest_value, Json, B1Error, ZERO_LINK};
use std::collections::BTreeMap;
use std::fmt;
use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Origin {
    /// User-literal: explicitly requested, stated, constrained or authorized by the user.
    U,
    /// Model-derived: derived by the system because it materially advances U.
    M,
    /// Platform-generated: produced by the surrounding platform, runtime, provider or toolchain.
    P,
    /// Emergent: arose through interaction; no single actor cleanly explains it.
    E,
    Unknown,
}

impl Origin {
    pub fn as_str(self) -> &'static str {
        match self {
            Origin::U => "U",
            Origin::M => "M",
            Origin::P => "P",
            Origin::E => "E",
            Origin::Unknown => "UNKNOWN",
        }
    }
    pub fn parse(s: &str) -> Origin {
        match s {
            "U" => Origin::U,
            "M" => Origin::M,
            "P" => Origin::P,
            "E" => Origin::E,
            // An unrecognized origin is UNKNOWN, never U. Defaulting to U would silently
            // attribute system-derived work to the user (law L2).
            _ => Origin::Unknown,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EffectClass {
    Reversible,
    Compensatable,
    Irreversible,
    Unknown,
}

impl EffectClass {
    pub fn as_str(self) -> &'static str {
        match self {
            EffectClass::Reversible => "REVERSIBLE",
            EffectClass::Compensatable => "COMPENSATABLE",
            EffectClass::Irreversible => "IRREVERSIBLE",
            EffectClass::Unknown => "UNKNOWN",
        }
    }
    pub fn parse(s: &str) -> EffectClass {
        match s {
            "REVERSIBLE" => EffectClass::Reversible,
            "COMPENSATABLE" => EffectClass::Compensatable,
            "IRREVERSIBLE" => EffectClass::Irreversible,
            _ => EffectClass::Unknown,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Validity {
    Verified,
    WorkingAssumption,
    Unknown,
    InDoubt,
}

impl Validity {
    pub fn as_str(self) -> &'static str {
        match self {
            Validity::Verified => "VERIFIED",
            Validity::WorkingAssumption => "WORKING_ASSUMPTION",
            Validity::Unknown => "UNKNOWN",
            Validity::InDoubt => "IN_DOUBT",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Verified,
    Partial,
    Failed,
    InDoubt,
    NotExecuted,
}

impl Outcome {
    pub fn as_str(self) -> &'static str {
        match self {
            Outcome::Verified => "VERIFIED",
            Outcome::Partial => "PARTIAL",
            Outcome::Failed => "FAILED",
            Outcome::InDoubt => "IN_DOUBT",
            Outcome::NotExecuted => "NOT_EXECUTED",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Action {
    pub kind: String,
    pub summary: String,
    pub target: String,
    pub persistent: bool,
}

#[derive(Debug, Clone)]
pub struct Receipt {
    /// What the executor said happened. Evidence, never proof.
    pub executor_claim: String,
    pub status_code: Option<String>,
    pub received_at_ms: i64,
}

#[derive(Debug, Clone)]
pub struct ObservedEffect {
    /// What was independently observed — not what was claimed.
    pub observation: String,
    pub observer: String,
    pub observed_at_ms: i64,
    pub media_digest: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Postcondition {
    pub statement: String,
    pub satisfied: bool,
    pub method: String,
    pub unmet: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct EffectTimeValidation {
    pub checked_at_ms: i64,
    pub gate_state: String,
    pub recomputed_envelope_digest: String,
    pub matched: bool,
    pub detail: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Record {
    pub seq: i64,
    pub prev_link: String,
    pub record_id: String,

    pub goal: String,
    pub derived_need: String,
    pub origin: Origin,
    pub causal_parents: Vec<String>,

    pub authority: String,
    pub authorization_ref: Option<String>,
    pub envelope_digest: Option<String>,
    pub effect_time_validation: Option<EffectTimeValidation>,

    /// Program identity: which logical component was supposed to act.
    pub executor: String,
    /// Which concrete runtime, process, provider instance or agent acted.
    pub execution_identity: String,
    /// Which attempt produced this. A retry is a new attempt, never the same one.
    pub attempt_identity: String,

    pub action: Action,
    pub receipt: Option<Receipt>,
    pub observed_effect: Option<ObservedEffect>,
    pub objective_postcondition: Option<Postcondition>,

    pub persistent_id: Option<String>,
    pub user_visible: bool,
    pub reason_persisted: Option<String>,
    pub effect_class: EffectClass,

    pub evidence: Vec<(String, String)>,
    pub present_validity: Validity,
    pub observed_at_ms: i64,
}

fn opt_str(v: &Option<String>) -> Json {
    match v {
        Some(s) => Json::s(s.clone()),
        None => Json::Null,
    }
}

impl Record {
    /// The record body: everything except `record_id`, which is the digest of this.
    pub fn body(&self) -> Json {
        let mut m: BTreeMap<String, Json> = BTreeMap::new();
        m.insert("seq".into(), Json::Int(self.seq));
        m.insert("prev_link".into(), Json::s(self.prev_link.clone()));
        m.insert("goal".into(), Json::s(self.goal.clone()));
        m.insert("derived_need".into(), Json::s(self.derived_need.clone()));
        m.insert("origin".into(), Json::s(self.origin.as_str()));
        m.insert(
            "causal_parents".into(),
            Json::Arr(self.causal_parents.iter().map(Json::s).collect()),
        );
        m.insert("authority".into(), Json::s(self.authority.clone()));
        m.insert("authorization_ref".into(), opt_str(&self.authorization_ref));
        m.insert("envelope_digest".into(), opt_str(&self.envelope_digest));
        m.insert(
            "effect_time_validation".into(),
            match &self.effect_time_validation {
                None => Json::Null,
                Some(v) => Json::obj(vec![
                    ("checked_at_ms", Json::Int(v.checked_at_ms)),
                    ("gate_state", Json::s(v.gate_state.clone())),
                    (
                        "recomputed_envelope_digest",
                        Json::s(v.recomputed_envelope_digest.clone()),
                    ),
                    ("matched", Json::Bool(v.matched)),
                    ("detail", opt_str(&v.detail)),
                ]),
            },
        );
        m.insert("executor".into(), Json::s(self.executor.clone()));
        m.insert(
            "execution_identity".into(),
            Json::s(self.execution_identity.clone()),
        );
        m.insert(
            "attempt_identity".into(),
            Json::s(self.attempt_identity.clone()),
        );
        m.insert(
            "action".into(),
            Json::obj(vec![
                ("kind", Json::s(self.action.kind.clone())),
                ("summary", Json::s(self.action.summary.clone())),
                ("target", Json::s(self.action.target.clone())),
                ("persistent", Json::Bool(self.action.persistent)),
            ]),
        );
        m.insert(
            "receipt".into(),
            match &self.receipt {
                None => Json::Null,
                Some(r) => Json::obj(vec![
                    ("executor_claim", Json::s(r.executor_claim.clone())),
                    ("status_code", opt_str(&r.status_code)),
                    ("received_at_ms", Json::Int(r.received_at_ms)),
                ]),
            },
        );
        m.insert(
            "observed_effect".into(),
            match &self.observed_effect {
                None => Json::Null,
                Some(o) => Json::obj(vec![
                    ("observation", Json::s(o.observation.clone())),
                    ("observer", Json::s(o.observer.clone())),
                    ("observed_at_ms", Json::Int(o.observed_at_ms)),
                    ("media_digest", opt_str(&o.media_digest)),
                ]),
            },
        );
        m.insert(
            "objective_postcondition".into(),
            match &self.objective_postcondition {
                None => Json::Null,
                Some(p) => Json::obj(vec![
                    ("statement", Json::s(p.statement.clone())),
                    ("satisfied", Json::Bool(p.satisfied)),
                    ("method", Json::s(p.method.clone())),
                    ("unmet", Json::Arr(p.unmet.iter().map(Json::s).collect())),
                ]),
            },
        );
        m.insert("persistent_id".into(), opt_str(&self.persistent_id));
        m.insert("user_visible".into(), Json::Bool(self.user_visible));
        m.insert("reason_persisted".into(), opt_str(&self.reason_persisted));
        m.insert("effect_class".into(), Json::s(self.effect_class.as_str()));
        m.insert(
            "evidence".into(),
            Json::Arr(
                self.evidence
                    .iter()
                    .map(|(k, d)| {
                        Json::obj(vec![("kind", Json::s(k.clone())), ("detail", Json::s(d.clone()))])
                    })
                    .collect(),
            ),
        );
        m.insert(
            "present_validity".into(),
            Json::s(self.present_validity.as_str()),
        );
        m.insert("observed_at_ms".into(), Json::Int(self.observed_at_ms));
        Json::Obj(m)
    }

    /// Seals the record: computes `record_id` from the body.
    pub fn seal(&mut self) -> Result<(), B1Error> {
        self.record_id = b1c1(&digest_value(&self.body())?);
        Ok(())
    }

    pub fn to_json(&self) -> Json {
        let mut v = self.body();
        if let Json::Obj(ref mut m) = v {
            m.insert("record_id".into(), Json::s(self.record_id.clone()));
        }
        v
    }

    /// Classifies the outcome. Note the three separate routes into `InDoubt` before `Verified`
    /// becomes reachable, and that a receipt alone never reaches it (law L3).
    pub fn outcome(&self) -> Outcome {
        if self.receipt.is_none() && self.observed_effect.is_none() {
            return Outcome::NotExecuted;
        }
        if self.receipt.is_none() {
            return Outcome::InDoubt;
        }
        let Some(observed) = &self.observed_effect else {
            return Outcome::InDoubt; // a receipt on its own proves nothing
        };
        let _ = observed;
        let Some(post) = &self.objective_postcondition else {
            return Outcome::InDoubt;
        };
        if post.satisfied && post.unmet.is_empty() {
            Outcome::Verified
        } else if post.unmet.len() < 3 && !post.satisfied {
            Outcome::Partial
        } else if post.satisfied {
            Outcome::Partial
        } else {
            Outcome::Failed
        }
    }
}

#[derive(Debug)]
pub enum ChainError {
    /// A record's own digest does not match its contents: the record was altered.
    RecordAltered { seq: i64, expected: String, actual: String },
    /// A record's prev_link does not match the previous record: history was reordered or spliced.
    LinkBroken { seq: i64, expected: String, actual: String },
    /// Sequence numbers are not consecutive from zero: a record was inserted or removed.
    SequenceGap { expected: i64, actual: i64 },
    Malformed { line: usize, detail: String },
}

impl fmt::Display for ChainError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ChainError::RecordAltered { seq, expected, actual } => write!(
                f,
                "record {seq} altered: contents hash to {actual}, but it carries {expected}"
            ),
            ChainError::LinkBroken { seq, expected, actual } => write!(
                f,
                "chain broken at {seq}: prev_link is {actual}, previous record is {expected}"
            ),
            ChainError::SequenceGap { expected, actual } => {
                write!(f, "sequence gap: expected seq {expected}, found {actual}")
            }
            ChainError::Malformed { line, detail } => {
                write!(f, "malformed record on line {line}: {detail}")
            }
        }
    }
}

#[derive(Debug)]
pub enum SealError {
    NotAnObject,
    /// The body claimed a field the chain assigns.
    ReservedField(&'static str),
    MissingFields(Vec<String>),
    Canon(B1Error),
    Io(std::io::Error),
}

impl fmt::Display for SealError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SealError::NotAnObject => write!(f, "a record body must be a JSON object"),
            SealError::ReservedField(name) => write!(
                f,
                "the body sets `{name}`, which the chain assigns; a caller that picks its own \
                 position in history is not recording, it is forging"
            ),
            SealError::MissingFields(fields) => {
                write!(f, "the body is missing required field(s): {}", fields.join(", "))
            }
            SealError::Canon(e) => write!(f, "body is not canonicalizable: {}", e.token()),
            SealError::Io(e) => write!(f, "{e}"),
        }
    }
}

pub struct Ledger {
    path: String,
}

impl Ledger {
    pub fn new(path: impl AsRef<Path>) -> Ledger {
        Ledger {
            path: path.as_ref().to_string_lossy().into_owned(),
        }
    }

    pub fn read_lines(&self) -> std::io::Result<Vec<String>> {
        if !Path::new(&self.path).exists() {
            return Ok(Vec::new());
        }
        let file = std::fs::File::open(&self.path)?;
        BufReader::new(file).lines().collect()
    }

    pub fn next_seq(&self) -> std::io::Result<i64> {
        Ok(self.read_lines()?.len() as i64)
    }

    pub fn tail_link(&self) -> std::io::Result<String> {
        let lines = self.read_lines()?;
        match lines.last() {
            None => Ok(ZERO_LINK.to_string()),
            Some(line) => {
                let v = crate::canon::parse(line).map_err(|e| {
                    std::io::Error::new(std::io::ErrorKind::InvalidData, e.token())
                })?;
                Ok(v.get("record_id")
                    .and_then(|j| j.as_str())
                    .unwrap_or(ZERO_LINK)
                    .to_string())
            }
        }
    }

    /// Appends a sealed record. The file stores each record's canonical form, so the bytes on disk
    /// are reproducible from the record and verification is a byte comparison.
    pub fn append(&self, record: &Record) -> std::io::Result<()> {
        self.append_value(&record.to_json())
    }

    /// Appends an already-sealed record value.
    ///
    /// Exists so a caller in another language can supply record *content* over IF-1 while sealing
    /// and chaining stay here. Splitting it the other way — letting the caller compute its own
    /// `record_id` and `prev_link` — would move the integrity guarantee out of the component that
    /// exists to hold it.
    pub fn append_value(&self, value: &Json) -> std::io::Result<()> {
        let line = crate::canon::canonicalize(value)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.token()))?;
        if let Some(parent) = Path::new(&self.path).parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut f = OpenOptions::new().create(true).append(true).open(&self.path)?;
        writeln!(f, "{line}")
    }

    /// Seals a caller-supplied record body and appends it, returning the assigned `record_id`.
    ///
    /// `seq`, `prev_link` and `record_id` are the chain's to assign. A body arriving with any of
    /// them set is rejected rather than overwritten: accepting one would let a caller claim a
    /// position in history, and silently replacing it would hide that they tried.
    pub fn seal_and_append(&self, body: &Json) -> Result<String, SealError> {
        let Json::Obj(members) = body else {
            return Err(SealError::NotAnObject);
        };

        for reserved in ["seq", "prev_link", "record_id"] {
            if members.contains_key(reserved) {
                return Err(SealError::ReservedField(reserved));
            }
        }

        const REQUIRED: [&str; 9] = [
            "goal", "derived_need", "origin", "authority", "executor", "execution_identity",
            "attempt_identity", "action", "present_validity",
        ];
        let missing: Vec<&str> = REQUIRED
            .into_iter()
            .filter(|f| !members.contains_key(*f))
            .collect();
        if !missing.is_empty() {
            return Err(SealError::MissingFields(
                missing.iter().map(|s| s.to_string()).collect(),
            ));
        }

        let seq = self.next_seq().map_err(SealError::Io)?;
        let prev = self.tail_link().map_err(SealError::Io)?;

        let mut sealed = members.clone();
        sealed.insert("seq".into(), Json::Int(seq));
        sealed.insert("prev_link".into(), Json::s(prev));

        let body_value = Json::Obj(sealed.clone());
        let record_id = b1c1(&digest_value(&body_value).map_err(SealError::Canon)?);

        sealed.insert("record_id".into(), Json::s(record_id.clone()));
        self.append_value(&Json::Obj(sealed)).map_err(SealError::Io)?;

        Ok(record_id)
    }

    /// Walks the chain from seq 0, recomputing every digest and link.
    ///
    /// This is tamper-*evident*, not tamper-proof: a party who can rewrite the whole file can
    /// rebuild a consistent chain. It defends against the realistic threats — silent corruption,
    /// partial writes, accidental edits, and a component quietly "fixing" history — and claiming
    /// more than that would be exactly the unearned certainty this system exists to prevent.
    pub fn verify(&self) -> std::io::Result<Result<usize, ChainError>> {
        let lines = self.read_lines()?;
        let mut prev = ZERO_LINK.to_string();

        for (idx, line) in lines.iter().enumerate() {
            if line.trim().is_empty() {
                continue;
            }
            let parsed = match crate::canon::parse(line) {
                Ok(v) => v,
                Err(e) => {
                    return Ok(Err(ChainError::Malformed {
                        line: idx + 1,
                        detail: e.token().to_string(),
                    }))
                }
            };

            let Json::Obj(mut map) = parsed else {
                return Ok(Err(ChainError::Malformed {
                    line: idx + 1,
                    detail: "not an object".into(),
                }));
            };

            let carried_id = match map.remove("record_id").and_then(|j| j.as_str().map(String::from))
            {
                Some(s) => s,
                None => {
                    return Ok(Err(ChainError::Malformed {
                        line: idx + 1,
                        detail: "missing record_id".into(),
                    }))
                }
            };

            let seq = map.get("seq").and_then(Json::as_int).unwrap_or(-1);
            if seq != idx as i64 {
                return Ok(Err(ChainError::SequenceGap {
                    expected: idx as i64,
                    actual: seq,
                }));
            }

            let link = map
                .get("prev_link")
                .and_then(Json::as_str)
                .unwrap_or("")
                .to_string();
            if link != prev {
                return Ok(Err(ChainError::LinkBroken {
                    seq,
                    expected: prev,
                    actual: link,
                }));
            }

            let body = Json::Obj(map);
            let recomputed = match digest_value(&body) {
                Ok(d) => b1c1(&d),
                Err(e) => {
                    return Ok(Err(ChainError::Malformed {
                        line: idx + 1,
                        detail: e.token().to_string(),
                    }))
                }
            };
            if recomputed != carried_id {
                return Ok(Err(ChainError::RecordAltered {
                    seq,
                    expected: carried_id,
                    actual: recomputed,
                }));
            }

            prev = carried_id;
        }

        Ok(Ok(lines.iter().filter(|l| !l.trim().is_empty()).count()))
    }
}
