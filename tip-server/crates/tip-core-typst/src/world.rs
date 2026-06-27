use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use typst::diag::{FileError, FileResult};
use typst::foundations::{Bytes, Datetime, Duration};
use typst::syntax::{FileId, RootedPath, Source, VirtualPath, VirtualRoot};
use typst::text::{Font, FontBook};
use typst::utils::LazyHash;
use typst::{Library, LibraryExt, World};
use typst_kit::downloader::SystemDownloader;
use typst_kit::files::FsRoot;
use typst_kit::fonts::FontStore;
use typst_kit::packages::{FsPackages, SystemPackages, UniversePackages};
use typst_library::Feature;

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
    /// Lazily loaded fonts and metadata.
    fonts: FontStore,
    /// Number of font faces discovered while building the world.
    font_count: usize,
    /// In-memory source storage, keyed by FileId.
    sources: Mutex<HashMap<FileId, Source>>,
    /// Package storage for resolving @preview/... imports.
    packages: SystemPackages,
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
            package_data_dir: None,
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

    /// Set the main file's virtual path to match a real file URI.
    /// This ensures relative imports in the scope skeleton resolve correctly
    /// (e.g., `#import "../_lib/kodama.typ"` from a file in a subdirectory).
    pub fn set_main_path(&mut self, file_uri: &str) {
        if let Some(root) = &self.root {
            if let Ok(vpath) = VirtualPath::virtualize(root, Path::new(file_uri)) {
                let new_id = FileId::unique(RootedPath::new(VirtualRoot::Project, vpath));
                // Move existing source to new ID
                let mut sources = self.sources.lock().unwrap();
                if let Some(source) = sources.remove(&self.main) {
                    let new_source = Source::new(new_id, source.text().to_string());
                    sources.insert(new_id, new_source);
                }
                self.main = new_id;
            }
        }
    }

    /// Get the main FileId.
    pub fn main_id(&self) -> FileId {
        self.main
    }

    /// How many fonts the FontSearcher discovered.  Used by the
    /// server's `health_check` handler for diagnostic reporting.
    pub fn font_count(&self) -> usize {
        self.font_count
    }

    /// Reset compilation state (evict stale memoization entries).
    pub fn reset(&mut self) {
        comemo::evict(10);
    }

    /// Resolve a FileId to a filesystem path.
    fn resolve_path(&self, id: FileId) -> FileResult<PathBuf> {
        match id.root() {
            VirtualRoot::Package(spec) => {
                // Package import: resolve via Typst's system package locations.
                let root = self
                    .packages
                    .obtain(spec)
                    .map_err(|e| FileError::Other(Some(format!("{e}").into())))?;
                root.resolve(id.vpath())
            }
            VirtualRoot::Project => {
                // Project-local import: resolve relative to project root.
                let root = self.root.as_deref().ok_or_else(|| {
                    FileError::Other(Some("no project root set; cannot resolve imports".into()))
                })?;
                FsRoot::new(root.to_path_buf()).resolve(id.vpath())
            }
        }
    }

    /// Read a source file from disk, caching it.
    fn read_source_from_disk(&self, id: FileId) -> FileResult<Source> {
        let path = self.resolve_path(id)?;
        let text = std::fs::read_to_string(&path)
            .map_err(|e| FileError::Other(Some(format!("{}: {}", path.display(), e).into())))?;
        let source = Source::new(id, text);
        self.sources.lock().unwrap().insert(id, source.clone());
        Ok(source)
    }

    /// Read a binary file from disk.
    fn read_file_from_disk(&self, id: FileId) -> FileResult<Bytes> {
        let path = self.resolve_path(id)?;
        let data = std::fs::read(&path)
            .map_err(|e| FileError::Other(Some(format!("{}: {}", path.display(), e).into())))?;
        Ok(Bytes::new(data))
    }
}

pub struct TipWorldBuilder {
    root: Option<PathBuf>,
    font_dirs: Vec<PathBuf>,
    package_data_dir: Option<PathBuf>,
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

    pub fn package_data_dir(mut self, dir: impl Into<PathBuf>) -> Self {
        self.package_data_dir = Some(dir.into());
        self
    }

    pub fn build(self) -> TipWorld {
        let features = [Feature::Html].into_iter().collect();
        let library = Library::builder().with_features(features).build();

        // Combine custom dirs with TYPST_FONT_PATHS env var
        let mut all_dirs = self.font_dirs;
        if let Ok(val) = std::env::var("TYPST_FONT_PATHS") {
            for p in val.split(if cfg!(windows) { ';' } else { ':' }) {
                if !p.is_empty() {
                    all_dirs.push(PathBuf::from(p));
                }
            }
        }

        let mut fonts = FontStore::new();
        let mut font_count = 0;

        let embedded = typst_kit::fonts::embedded().collect::<Vec<_>>();
        font_count += embedded.len();
        fonts.extend(embedded);

        for dir in &all_dirs {
            let scanned = typst_kit::fonts::scan(dir).collect::<Vec<_>>();
            font_count += scanned.len();
            fonts.extend(scanned);
        }

        let system = typst_kit::fonts::system().collect::<Vec<_>>();
        font_count += system.len();
        fonts.extend(system);

        let main = FileId::unique(RootedPath::new(
            VirtualRoot::Project,
            VirtualPath::new("tip-main.typ").expect("valid virtual path"),
        ));

        let downloader = SystemDownloader::new("tip-server/0.1.0");
        let packages = match self.package_data_dir {
            Some(dir) => SystemPackages::from_parts(
                Some(FsPackages::new(dir)),
                FsPackages::system_cache(),
                UniversePackages::new(downloader),
            ),
            None => SystemPackages::new(downloader),
        };

        TipWorld {
            main,
            root: self.root,
            library: LazyHash::new(library),
            fonts,
            font_count,
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
        self.fonts.book()
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
        self.fonts.font(index)
    }

    fn today(&self, _offset: Option<Duration>) -> Option<Datetime> {
        None
    }
}
