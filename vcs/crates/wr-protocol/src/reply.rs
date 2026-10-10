//! The reply every request/reply service sends on its stream: `{"version": N, "result": …}` when
//! the request succeeded, `{"version": N, "error": …}` when it did not. `N` is the service's own
//! version, not the envelope's. The body is each service's business; only this outer shape is
//! shared, so it is written once here rather than as a `json!` literal at every reply site.
use serde::Serialize;

/// One reply. Serialize it (with `serde_json::to_value` or `json!`) to put it on the wire.
///
/// The outcome is declared before `version` so that serializing a `Reply` directly writes the
/// same bytes as serializing it through a `serde_json::Value`, whose keys are sorted.
#[derive(Debug, Serialize)]
pub struct Reply<T, E> {
    #[serde(flatten)]
    outcome: Outcome<T, E>,
    version: u32,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "lowercase")]
enum Outcome<T, E> {
    Result(T),
    Error(E),
}

impl<T, E> Reply<T, E> {
    /// `result` on success, `error` on failure.
    pub fn new(version: u32, outcome: Result<T, E>) -> Self {
        let outcome = match outcome {
            Ok(result) => Outcome::Result(result),
            Err(error) => Outcome::Error(error),
        };
        Reply { outcome, version }
    }
}

impl<T> Reply<T, ()> {
    /// A success.
    pub fn result(version: u32, result: T) -> Self {
        Reply::new(version, Ok(result))
    }
}

impl<E> Reply<(), E> {
    /// A failure.
    pub fn error(version: u32, error: E) -> Self {
        Reply::new(version, Err(error))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// The bytes are the ones the services built by hand before this type existed, so no client
    /// sees a difference.
    #[test]
    fn a_reply_is_the_shape_every_client_decodes() {
        let cases = [
            (
                json!(Reply::result(1, json!({"opened": true}))),
                r#"{"result":{"opened":true},"version":1}"#,
            ),
            (
                json!(Reply::error(2, json!({"unsupported": "gone"}))),
                r#"{"error":{"unsupported":"gone"},"version":2}"#,
            ),
            (
                json!(Reply::<(), _>::new(1, Err("LockContention"))),
                r#"{"error":"LockContention","version":1}"#,
            ),
            (
                json!(Reply::<_, ()>::new(3, Ok(json!(null)))),
                r#"{"result":null,"version":3}"#,
            ),
        ];
        for (reply, wire) in cases {
            assert_eq!(serde_json::to_string(&reply).unwrap(), wire);
        }
        assert_eq!(
            serde_json::to_string(&Reply::error(1, "LockContention")).unwrap(),
            r#"{"error":"LockContention","version":1}"#,
            "serialized directly, not through a Value"
        );
        let old = json!({"version": 1, "result": {"opened": true}});
        assert_eq!(
            serde_json::to_vec(&json!(Reply::result(1, json!({"opened": true})))).unwrap(),
            serde_json::to_vec(&old).unwrap()
        );
    }
}
