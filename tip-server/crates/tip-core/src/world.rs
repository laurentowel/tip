use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use typst::diag::{FileError, FileResult};
use typst::foundations::{Bytes, Datetime};
use typst::syntax::{FileId, Source, VirtualPath};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt, World};
use typst_kit::download::{Downloader, ProgressSink};
use typst_kit::fonts::{FontSearcher, FontSlot, Fonts};
use typst_kit::package::PackageStorage;

/// A World implementation for TIP that keeps the main source in memory
/// (synced from the editor) and resolves imports from the filesystem
/// and package registry.
pub struct TipWorld {
    /// The main file ID (in-memory, synced from editor).
    main: FileId,
    /// Project root directory for resolving relative imports.
    root: Option<PathBuf>,
    /// Typst's standard library.
    library: LazyHash<Library>,
    /// Font metadata.
    book: LazyHash<FontBook>,
    /// Lazily loaded fonts.
    fonts: Vec<FontSlot>,
    /// In-memory source storage, keyed by FileId.
    sources: Mutex<HashMap<FileId, Source>>,
    /// Package storage for resolving @preview/... imports.
    packages: PackageStorage,
}

impl TipWorld {
    /// Create a new TipWorld with embedded + system fonts and no project root.
    pub fn new() -> Self {
        Self::builder().build()
    }

    /// Create a new TipWorld with additional font directories.
    pub fn with_font_dirs<P: AsRef<Path>>(font_dirs: &[P]) -> Self {
        let mut builder = Self::builder();
        for dir in font_dirs {
            builder = builder.font_dir(dir.as_ref());
        }
        builder.build()
    }

    /// Create a builder for configuring a TipWorld.
    pub fn builder() -> TipWorldBuilder {
        TipWorldBuilder {
            root: None,
            font_dirs: Vec::new(),
        }
    }

    /// Set the source content for the main document.
    pub fn set_main_source(&mut self, content: &str) {
        let source = Source::new(self.main, content.to_string());
        self.sources.lock().unwrap().insert(self.main, source);
    }

    /// Set the project root for resolving imports.
    pub fn set_root(&mut self, root: PathBuf) {
        self.root = Some(root);
    }

    /// Get the main FileId.
    pub fn main_id(&self) -> FileId {
        self.main
    }

    /// Reset compilation state (evict stale memoization entries).
    pub fn reset(&mut self) {
        comemo::evict(10);
    }

    /// Resolve a FileId to a filesystem path.
    fn resolve_path(&self, id: FileId) -> FileResult<PathBuf> {
        if let Some(spec) = id.package() {
            // Package import: resolve via PackageStorage
            let dir = self
                .packages
                .prepare_package(spec, &mut ProgressSink)
                .map_err(|e| FileError::Other(Some(format!("{e}").into())))?;
            let resolved = id.vpath().resolve(&dir).ok_or_else(|| {
                FileError::NotFound(id.vpath().as_rootless_path().into())
            })?;
            Ok(resolved)
        } else {
            // Project-local import: resolve relative to project root
            let root = self.root.as_deref().ok_or_else(|| {
                FileError::Other(Some(
                    "no project root set; cannot resolve imports".into(),
                ))
            })?;
            id.vpath()
                .resolve(root)
                .ok_or_else(|| FileError::NotFound(id.vpath().as_rootless_path().into()))
        }
    }

    /// Read a source file from disk, caching it.
    fn read_source_from_disk(&self, id: FileId) -> FileResult<Source> {
        let path = self.resolve_path(id)?;
        let text = std::fs::read_to_string(&path).map_err(|e| {
            FileError::Other(Some(format!("{}: {}", path.display(), e).into()))
        })?;
        let source = Source::new(id, text);
        self.sources.lock().unwrap().insert(id, source.clone());
        Ok(source)
    }

    /// Read a binary file from disk.
    fn read_file_from_disk(&self, id: FileId) -> FileResult<Bytes> {
        let path = self.resolve_path(id)?;
        let data = std::fs::read(&path).map_err(|e| {
            FileError::Other(Some(format!("{}: {}", path.display(), e).into()))
        })?;
        Ok(Bytes::new(data))
    }
}

pub struct TipWorldBuilder {
    root: Option<PathBuf>,
    font_dirs: Vec<PathBuf>,
}

impl TipWorldBuilder {
    pub fn root(mut self, root: impl Into<PathBuf>) -> Self {
        self.root = Some(root.into());
        self
    }

    pub fn font_dir(mut self, dir: &Path) -> Self {
        self.font_dirs.push(dir.to_path_buf());
        self
    }

    pub fn build(self) -> TipWorld {
        let library = Library::builder().build();

        let discovered: Fonts =
            FontSearcher::new().search_with(self.font_dirs.iter().map(|p| p.as_path()));

        let main = FileId::new_fake(VirtualPath::new("tip-main.typ"));

        let downloader = Downloader::new("tip-server/0.1.0");
        let packages = PackageStorage::new(None, None, downloader);

        TipWorld {
            main,
            root: self.root,
            library: LazyHash::new(library),
            book: LazyHash::new(discovered.book),
            fonts: discovered.fonts,
            sources: Mutex::new(HashMap::new()),
            packages,
        }
    }
}

impl World for TipWorld {
    fn library(&self) -> &LazyHash<Library> {
        &self.library
    }

    fn book(&self) -> &LazyHash<FontBook> {
        &self.book
    }

    fn main(&self) -> FileId {
        self.main
    }

    fn source(&self, id: FileId) -> FileResult<Source> {
        // Check in-memory sources first
        if let Some(source) = self.sources.lock().unwrap().get(&id) {
            return Ok(source.clone());
        }
        // Fall back to filesystem / package storage
        self.read_source_from_disk(id)
    }

    fn file(&self, id: FileId) -> FileResult<Bytes> {
        // Check in-memory sources first
        let sources = self.sources.lock().unwrap();
        if let Some(source) = sources.get(&id) {
            return Ok(Bytes::from_string(source.clone()));
        }
        drop(sources);
        // Fall back to filesystem / package storage
        self.read_file_from_disk(id)
    }

    fn font(&self, index: usize) -> Option<Font> {
        self.fonts.get(index)?.get()
    }

    fn today(&self, _offset: Option<i64>) -> Option<Datetime> {
        None
    }
}
