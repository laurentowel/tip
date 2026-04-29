//! In-memory document store keyed by URI.
//!
//! Every backend tracks an editor-synced copy of each open buffer, so
//! `compile_fragments` calls can byte-index into the source.  All
//! backends use the same `HashMap<String, String>` shape; this module
//! is the single home so the typst, latex, and katex crates share one
//! impl + one set of tests.

use std::collections::HashMap;

/// Editor-synced documents keyed by URI.  `sync(uri, content)` inserts
/// or replaces; `get(uri)` returns a borrow of the current content.
#[derive(Debug, Default)]
pub struct DocumentStore {
    documents: HashMap<String, String>,
}

impl DocumentStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Update (or insert) the content for a document URI.
    pub fn sync(&mut self, uri: String, content: String) {
        self.documents.insert(uri, content);
    }

    /// Borrow the content for a document URI, or `None` if not synced.
    pub fn get(&self, uri: &str) -> Option<&str> {
        self.documents.get(uri).map(String::as_str)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sync_and_get() {
        let mut store = DocumentStore::new();
        store.sync("/test.typ".into(), "$a + b$".into());
        assert_eq!(store.get("/test.typ"), Some("$a + b$"));
    }

    #[test]
    fn sync_overwrites() {
        let mut store = DocumentStore::new();
        store.sync("/test.typ".into(), "old".into());
        store.sync("/test.typ".into(), "new".into());
        assert_eq!(store.get("/test.typ"), Some("new"));
    }

    #[test]
    fn get_missing_returns_none() {
        let store = DocumentStore::new();
        assert_eq!(store.get("/missing.typ"), None);
    }
}
