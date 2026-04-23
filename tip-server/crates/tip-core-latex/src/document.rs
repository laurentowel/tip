//! In-memory document store keyed by URI.  Parallels tip-core-typst's
//! `DocumentStore` but without the typst-specific caching concerns.

use std::collections::HashMap;

#[derive(Default)]
pub struct DocumentStore {
    docs: HashMap<String, String>,
}

impl DocumentStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn sync(&mut self, uri: String, content: String) {
        self.docs.insert(uri, content);
    }

    pub fn get(&self, uri: &str) -> Option<&str> {
        self.docs.get(uri).map(String::as_str)
    }
}
