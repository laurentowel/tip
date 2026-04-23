use std::collections::HashMap;

/// Manages document state synced from the editor.
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

    /// Get the content for a document URI.
    pub fn get(&self, uri: &str) -> Option<&str> {
        self.documents.get(uri).map(|s| s.as_str())
    }

    /// Check if a document is tracked.
    pub fn contains(&self, uri: &str) -> bool {
        self.documents.contains_key(uri)
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
