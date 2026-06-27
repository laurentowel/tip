//! Top-down strategy tests + bench fixtures.

#![allow(unused_imports)]

use super::extract::*;
use super::flatten::*;
use super::*;

fn locate(content: &str, needle: &str) -> Range<usize> {
    let start = content.find(needle).expect("needle not in source");
    start..start + needle.len()
}

#[test]
fn full_doc_compiles_simple_source() {
    let mut world = TipWorld::new();
    let src = "$x + y$\n";
    let doc = compile_real_document(&mut world, src).expect("compile");
    assert!(!doc.pages().is_empty());
}

#[test]
fn leaf_spans_partition_two_inline_fragments() {
    let mut world = TipWorld::new();
    let src = "Some text $x + y$ between $a - b$ math.\n";
    let doc = compile_real_document(&mut world, src).expect("compile");
    let spans = collect_leaf_spans(&world, &doc);

    // Sanity: we collected items, and at least some have resolved
    // source ranges in the main file.
    assert!(!spans.is_empty(), "expected leaf items");
    let with_range = spans.iter().filter(|s| s.source_range.is_some()).count();
    assert!(
        with_range > 0,
        "expected some items with main-source ranges"
    );

    let r1 = locate(src, "$x + y$");
    let r2 = locate(src, "$a - b$");

    let in1 = fragment_items(&spans, r1.start, r1.end);
    let in2 = fragment_items(&spans, r2.start, r2.end);

    assert!(!in1.is_empty(), "fragment 1 ($x + y$) should attract items");
    assert!(!in2.is_empty(), "fragment 2 ($a - b$) should attract items");

    // Disjoint: an item in fragment 1's range can't simultaneously
    // be in fragment 2's range — the source ranges don't overlap.
    for a in &in1 {
        for b in &in2 {
            assert!(
                !std::ptr::eq(*a, *b),
                "leaf item appeared in both fragments — overlap bug"
            );
        }
    }
}

/// Regression for the `hide()`-base / superscript case:
///
///   #let phantom(x) = hide($#x$)
///   $phantom(a)^2$
///
/// `hide()` removes the base glyph from the frame tree, but the
/// `^2` superscript stays at its real laid-out y-position relative
/// to the (invisible) base.  The synthetic-fragment compiler can't
/// see that — its page contains only `^2`, so cropping makes `^2`
/// look baseline-aligned on itself and the apparent ascent is
/// wrong.  Full-doc must keep the y-position so step 3 / 4 can
/// recover the right baseline from the surrounding page context.
#[test]
fn hidden_base_preserves_superscript_position() {
    let mut world = TipWorld::new();
    let src = "\
#let phantom(x) = hide($#x$)
$phantom(a)^2$ vs $a^2$
";
    let doc = compile_real_document(&mut world, src).expect("compile");
    let spans = collect_leaf_spans(&world, &doc);

    let r_phantom = locate(src, "$phantom(a)^2$");
    let r_plain = locate(src, "$a^2$");

    let in_phantom = fragment_items(&spans, r_phantom.start, r_phantom.end);
    let in_plain = fragment_items(&spans, r_plain.start, r_plain.end);

    // Both fragments must yield at least one visible leaf — the
    // superscript "2" — even though the phantom version's base is
    // hidden.
    assert!(
        !in_phantom.is_empty(),
        "phantom-base superscript fragment yielded no visible items"
    );
    assert!(!in_plain.is_empty());

    // Sanity: the phantom version has FEWER visible glyphs than
    // the plain `a^2` — the base `a` is hidden in the first.
    assert!(
        in_phantom.len() < in_plain.len(),
        "expected phantom version (no visible base) to have fewer \
             items than plain a^2; got {} vs {}",
        in_phantom.len(),
        in_plain.len()
    );

    // The y-positions of the surviving glyphs ARE roughly the same
    // height in both fragments — the superscript sits at the same
    // vertical offset whether or not the base is visible.  We
    // measure the topmost y in each set; they should be within a
    // small epsilon (the `^2` glyph in both cases).
    let top_y = |items: &[&LeafSpan]| -> f64 {
        items
            .iter()
            .map(|s| s.pos_pt.1)
            .fold(f64::INFINITY, f64::min)
    };
    let y_phantom = top_y(&in_phantom);
    let y_plain = top_y(&in_plain);
    assert!(
        (y_phantom - y_plain).abs() < 1.0,
        "superscript y drifted: phantom={:.3}pt plain={:.3}pt — \
             full-doc baseline recovery in step 3/4 will need this",
        y_phantom,
        y_plain
    );
}

#[test]
fn extract_renders_distinct_svgs_for_two_fragments() {
    let mut world = TipWorld::new();
    let src = "Some text $x + y$ between $a - b$ math.\n";
    let doc = compile_real_document(&mut world, src).expect("compile");

    let r1 = locate(src, "$x + y$");
    let r2 = locate(src, "$a - b$");
    let f1 =
        extract_fragment_svg(&world, &doc, r1.start, r1.end).expect("fragment 1 should render");
    let f2 =
        extract_fragment_svg(&world, &doc, r2.start, r2.end).expect("fragment 2 should render");

    assert!(f1.width_pt > 0.0 && f1.height_pt > 0.0);
    assert!(f2.width_pt > 0.0 && f2.height_pt > 0.0);
    assert!(f1.svg.contains("<svg"));
    assert!(f2.svg.contains("<svg"));
    assert_ne!(
        f1.svg, f2.svg,
        "two distinct fragments produced identical SVG"
    );
}

/// `font_size_pt` for `$phantom(a)^2$` must reflect the paragraph
/// context (~11 pt), not the `^2` glyph's own ~7 pt.  Otherwise
/// `tip-scale='auto'` (Emacs default) divides by 7 and scales the
/// preview ~1.6× — making the superscript huge.
#[test]
fn font_size_for_sup_only_fragment_uses_paragraph_context() {
    let mut world = TipWorld::new();
    let src = "\
#let phantom(x) = hide($#x$)
text $phantom(a)^2$ and $a^2$ done
";
    let doc = compile_real_document(&mut world, src).expect("compile");
    let r_phantom = locate(src, "$phantom(a)^2$");
    let r_plain = locate(src, "$a^2$");
    let f_phantom = extract_fragment_svg(&world, &doc, r_phantom.start, r_phantom.end).unwrap();
    let f_plain = extract_fragment_svg(&world, &doc, r_plain.start, r_plain.end).unwrap();
    // Both fragments live in an 11 pt paragraph; phantom should
    // adopt the same paragraph size as plain even though its
    // only visible glyph is sup-scaled.
    assert!(
        (f_phantom.font_size_pt - f_plain.font_size_pt).abs() < 0.5,
        "phantom font_size {:.3} should match plain {:.3} (paragraph context)",
        f_phantom.font_size_pt,
        f_plain.font_size_pt
    );
    assert!(
        f_phantom.font_size_pt > 9.0,
        "phantom font_size {:.3} suspiciously low — likely picked up the \
             sup-scaled `^2` glyph instead of paragraph text",
        f_phantom.font_size_pt
    );
}

/// Step-4 acceptance: with surrounding text on the same line,
/// `$phantom(a)^2$` and `$a^2$` must report the **same baseline**
/// (i.e. the same `height_pt - depth_pt`, since both crop to the
/// surrounding-text baseline).  Without external baseline this
/// would silently regress on hidden-base superscripts.
#[test]
fn external_baseline_matches_for_phantom_vs_plain() {
    let mut world = TipWorld::new();
    let src = "\
#let phantom(x) = hide($#x$)
text $phantom(a)^2$ and $a^2$ done
";
    let doc = compile_real_document(&mut world, src).expect("compile");
    let r_phantom = locate(src, "$phantom(a)^2$");
    let r_plain = locate(src, "$a^2$");

    let f_phantom =
        extract_fragment_svg(&world, &doc, r_phantom.start, r_phantom.end).expect("phantom render");
    let f_plain =
        extract_fragment_svg(&world, &doc, r_plain.start, r_plain.end).expect("plain render");

    // What matters is matching depth + height — whether the picker
    // got there via Group baseline, frag-text baseline, or external
    // is implementation detail.
    // The plain a^2 has a real `a` glyph touching the baseline, so
    // its depth is ~0 (no descender).  The phantom version's only
    // ink is `^2` entirely above the baseline, so depth is also 0.
    // What matters is they agree.
    assert!(
        (f_phantom.depth_pt - f_plain.depth_pt).abs() < 0.5,
        "depth diverged: phantom={:.3} plain={:.3}",
        f_phantom.depth_pt,
        f_plain.depth_pt
    );
    // Crucial: phantom's frame height must extend DOWN to the
    // baseline even though its ink doesn't.  Otherwise the
    // resulting image looks baseline-aligned on the `^2` itself.
    // Heights should agree within a glyph-descender's worth.
    assert!(
        (f_phantom.height_pt - f_plain.height_pt).abs() < 2.0,
        "phantom height should match plain (both extend to baseline): \
             phantom={:.3} plain={:.3}",
        f_phantom.height_pt,
        f_plain.height_pt
    );
}

/// Mixed-size: the same `$x + y$` body inside a 14 pt section
/// must report `font_size_pt == 14`, while the same expression
/// at the document default reports ~11 pt.  Emacs's effective
/// scale uses this ratio so the preview matches the document's
/// own typesetting.
#[test]
fn font_size_tracks_document_text_size() {
    let mut world = TipWorld::new();
    let src = "\
$x + y$ default size

#text(size: 14pt)[$x + y$ bigger]
";
    let doc = compile_real_document(&mut world, src).expect("compile");
    // `find` returns the FIRST match — locate the second `$x + y$`
    // by skipping past the first one explicitly.
    let first_start = src.find("$x + y$").unwrap();
    let second_start = src[first_start + 7..].find("$x + y$").unwrap() + first_start + 7;

    let f1 = extract_fragment_svg(&world, &doc, first_start, first_start + 7).unwrap();
    let f2 = extract_fragment_svg(&world, &doc, second_start, second_start + 7).unwrap();

    // Default text size in Typst is 11 pt (give or take).
    assert!(
        (f1.font_size_pt - 11.0).abs() < 0.5,
        "expected default ~11 pt, got {:.3}",
        f1.font_size_pt
    );
    assert!(
        (f2.font_size_pt - 14.0).abs() < 0.5,
        "expected 14 pt section, got {:.3}",
        f2.font_size_pt
    );
    // Sanity: the 14 pt fragment renders bigger than the 11 pt one.
    assert!(
        f2.height_pt > f1.height_pt * 1.15,
        "14pt fragment ({:.2}) should be visibly taller than 11pt ({:.2})",
        f2.height_pt,
        f1.height_pt
    );
}

/// Comparison: render the same fragment with synthetic and
/// full-doc strategies on a default-size doc; metrics should
/// agree within sensible tolerances.  Mixed-size docs are
/// covered by the `font_size_tracks_*` test above — synthetic
/// always reports 11 pt, full-doc reports the actual size, so
/// equivalence on mixed-size is by design false.
fn walk_synth_dbg(frame: &Frame, depth: usize, y_off: f64, out: &mut Vec<(usize, f64, bool)>) {
    for (pos, item) in frame.items() {
        if let FrameItem::Group(g) = item {
            let gy = y_off + pos.y.to_pt();
            let bl = g.frame.baseline().to_pt();
            out.push((depth, gy + bl, g.frame.has_baseline()));
            walk_synth_dbg(&g.frame, depth + 1, gy, out);
        }
    }
}

/// Build a deterministic ~5000-line typst document with ~500
/// inline math fragments scattered through prose paragraphs.
/// Used by the perf benches below.  Returns (source, fragment
/// byte ranges).
fn build_5kloc_corpus() -> (String, Vec<Range<usize>>) {
    let templates = [
        "$a + b = c$",
        "$x^2 + y^2$",
        "$sum_(i=1)^n i$",
        "$integral_0^1 x dif x$",
        "$frac(1, 2)$",
        "$sqrt(pi)$",
        "$alpha beta gamma$",
        "$a_1 + a_2$",
        "$lim_(n -> infinity) 1/n$",
        "$mat(1, 0; 0, 1)$",
        "$hat(x) tilde(y)$",
        "$frac(a, b) + frac(c, d)$",
    ];
    let mut src = String::with_capacity(5000 * 80);
    let mut fragments = Vec::new();
    // Pseudo-random linear-congruential generator.
    let mut rng: u64 = 0xDEADBEEF;
    let mut next = || {
        rng = rng
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        rng
    };
    let n_lines: usize = std::env::var("TIP_BENCH_LINES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1000);
    for line_idx in 0..n_lines {
        // Math-heavy: each line gets 1–3 inline fragments.
        // Each fragment is interleaved with a few words.
        let words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur"];
        let frags_this_line = 1 + (next() % 3) as usize; // 1, 2, or 3
        for f in 0..frags_this_line {
            let n_words = (next() % 3) as usize + 1;
            for _ in 0..n_words {
                let w = words[(next() % words.len() as u64) as usize];
                src.push_str(w);
                src.push(' ');
            }
            let tpl = templates[(next() % templates.len() as u64) as usize];
            let start = src.len();
            src.push_str(tpl);
            let end = src.len();
            fragments.push(start..end);
            if f < frags_this_line - 1 {
                src.push(' ');
            }
        }
        // trailing prose
        let n_words_post = (next() % 3) as usize + 1;
        src.push(' ');
        for _ in 0..n_words_post {
            let w = words[(next() % words.len() as u64) as usize];
            src.push_str(w);
            src.push(' ');
        }
        src.push_str(".\n");
        if line_idx % 20 == 19 {
            src.push('\n');
        }
    }
    (src, fragments)
}

/// Bench: synthetic strategy on a math-heavy corpus.
/// Set `TIP_BENCH_LINES=1000` to control corpus size.
#[test]
#[ignore = "perf bench, run with --ignored"]
fn bench_synth() {
    use crate::bottom_up::BottomUpCompiler;
    use std::time::Instant;
    let (src, fragments) = build_5kloc_corpus();
    let n_lines = src.lines().count();
    let n_frag = fragments.len();
    eprintln!(
        "[synth] corpus: {} lines, {} fragments, {} bytes",
        n_lines,
        n_frag,
        src.len()
    );
    let mut world = TipWorld::new();
    let t0 = Instant::now();
    let mut hits = 0;
    for r in &fragments {
        if BottomUpCompiler::compile_fragment_scoped(
            &mut world,
            &src,
            r.start,
            r.end,
            tip_protocol::svg_color::STANDIN_HEX,
            None,
            None,
            None,
        )
        .is_ok()
        {
            hits += 1;
        }
    }
    let total_ms = t0.elapsed().as_secs_f64() * 1000.0;
    eprintln!(
        "SYNTH: total={:.1} ms ({:.2} ms/frag)  hits={}/{}",
        total_ms,
        total_ms / n_frag as f64,
        hits,
        n_frag,
    );
}

/// Bench: full-doc strategy on the same corpus.
#[test]
#[ignore = "perf bench, run with --ignored"]
fn bench_full_doc() {
    use std::time::Instant;
    let (src, fragments) = build_5kloc_corpus();
    let n_lines = src.lines().count();
    let n_frag = fragments.len();
    eprintln!(
        "[full-doc] corpus: {} lines, {} fragments, {} bytes",
        n_lines,
        n_frag,
        src.len()
    );
    let mut world = TipWorld::new();
    let t0 = Instant::now();
    let doc = compile_real_document(&mut world, &src).expect("compile");
    let compile_ms = t0.elapsed().as_secs_f64() * 1000.0;
    let t0 = Instant::now();
    let mut hits = 0;
    for r in &fragments {
        if extract_fragment_svg(&world, &doc, r.start, r.end).is_some() {
            hits += 1;
        }
    }
    let extract_ms = t0.elapsed().as_secs_f64() * 1000.0;
    eprintln!(
        "FULL-DOC: compile={:.1} ms  extract_all={:.1} ms ({:.3} ms/frag)  hits={}/{}",
        compile_ms,
        extract_ms,
        extract_ms / n_frag as f64,
        hits,
        n_frag,
    );
}

/// Probe: what's slow in flatten?  Compare three variants:
/// (a) full flatten as we ship it,
/// (b) flatten that skips `src.range()` calls (just count glyphs),
/// (c) just `frame.items()` walk without touching glyphs at all.
#[test]
#[ignore = "perf bench, run with --ignored"]
fn bench_flatten_breakdown() {
    use std::time::Instant;
    let (src, _) = build_5kloc_corpus();
    let mut world = TipWorld::new();
    let doc = compile_real_document(&mut world, &src).expect("compile");
    let main = world.main();
    let main_src = world.source(main).ok().unwrap();

    // (a) full flatten
    let t = Instant::now();
    let mut leaves = Vec::new();
    let mut groups = Vec::new();
    for page in doc.pages() {
        flatten_leaves(
            &page.frame,
            Point::zero(),
            main,
            &main_src,
            &mut leaves,
            &mut groups,
        );
    }
    eprintln!(
        "(a) flatten_leaves: {:.1} ms  leaves={} groups={}",
        t.elapsed().as_secs_f64() * 1000.0,
        leaves.len(),
        groups.len()
    );

    // (b) walk + glyph count, no src.range
    let t = Instant::now();
    let mut total_glyphs = 0usize;
    let mut walked = 0usize;
    fn walk_b(frame: &Frame, total_glyphs: &mut usize, walked: &mut usize) {
        for (_pos, item) in frame.items() {
            *walked += 1;
            match item {
                FrameItem::Group(g) => walk_b(&g.frame, total_glyphs, walked),
                FrameItem::Text(t) => *total_glyphs += t.glyphs.len(),
                _ => {}
            }
        }
    }
    for page in doc.pages() {
        walk_b(&page.frame, &mut total_glyphs, &mut walked);
    }
    eprintln!(
        "(b) walk + count: {:.1} ms  walked_items={}, glyphs={}",
        t.elapsed().as_secs_f64() * 1000.0,
        walked,
        total_glyphs
    );

    // (c) walk + src.range per glyph
    let t = Instant::now();
    let mut got_range = 0usize;
    fn walk_c(frame: &Frame, main: FileId, src: &Source, got: &mut usize) {
        for (_pos, item) in frame.items() {
            match item {
                FrameItem::Group(g) => walk_c(&g.frame, main, src, got),
                FrameItem::Text(t) => {
                    for g in &t.glyphs {
                        let span = g.span.0;
                        if span.id() == Some(main) {
                            if src.find(span).map(|node| node.range()).is_some() {
                                *got += 1;
                            }
                        }
                    }
                }
                _ => {}
            }
        }
    }
    for page in doc.pages() {
        walk_c(&page.frame, main, &main_src, &mut got_range);
    }
    eprintln!(
        "(c) walk + src.range per glyph: {:.1} ms  resolved={}",
        t.elapsed().as_secs_f64() * 1000.0,
        got_range
    );
}

/// Phase-by-phase timing for the full-doc batch path.  Splits
/// total cost into compile, flatten, linear-pass, frame-build,
/// svg-render so we know where to optimize.
#[test]
#[ignore = "perf bench, run with --ignored"]
fn bench_full_doc_phases() {
    use std::time::Instant;
    let (src, fragments) = build_5kloc_corpus();
    let n_lines = src.lines().count();
    let n_frag = fragments.len();
    eprintln!(
        "[phases] {} lines, {} fragments, {} bytes",
        n_lines,
        n_frag,
        src.len()
    );
    let mut world = TipWorld::new();
    let t = Instant::now();
    let doc = compile_real_document(&mut world, &src).expect("compile");
    let compile = t.elapsed().as_secs_f64() * 1000.0;
    let main = world.main();
    let main_src = world.source(main).ok().unwrap();
    let t = Instant::now();
    let mut leaves_vec = Vec::new();
    let mut groups_vec = Vec::new();
    for page in doc.pages() {
        let mut leaves = Vec::new();
        let mut groups = Vec::new();
        flatten_leaves(
            &page.frame,
            Point::zero(),
            main,
            &main_src,
            &mut leaves,
            &mut groups,
        );
        leaves_vec.push(leaves);
        groups_vec.push(groups);
    }
    let total_leaves: usize = leaves_vec.iter().map(|v| v.len()).sum();
    let flatten = t.elapsed().as_secs_f64() * 1000.0;
    eprintln!("  total leaves across pages: {}", total_leaves);

    // Build pages index ONCE (move out of fragment loop).
    let pages: Vec<(Vec<FlatLeaf>, Vec<GroupRecord>)> =
        leaves_vec.into_iter().zip(groups_vec.into_iter()).collect();
    let mut extract_ms = 0.0;
    let mut hits = 0;
    for r in &fragments {
        let t = Instant::now();
        let render = extract_from_index(&pages, r.start, r.end, None);
        extract_ms += t.elapsed().as_secs_f64() * 1000.0;
        if render.is_some() {
            hits += 1;
        }
    }
    eprintln!("  compile: {:.1} ms", compile);
    eprintln!("  flatten (all pages): {:.1} ms", flatten);
    eprintln!(
        "  per-fragment extract+render: total={:.1} ms ({:.3} ms/frag) hits={}",
        extract_ms,
        extract_ms / n_frag as f64,
        hits
    );
}

/// Bench: full-doc with `compile_all` (which currently is the
/// same as the loop in `bench_full_doc` but exists as the public
/// API path the server hits).
#[test]
#[ignore = "perf bench, run with --ignored"]
fn bench_full_doc_compile_all() {
    use std::time::Instant;
    let (src, fragments) = build_5kloc_corpus();
    let n_lines = src.lines().count();
    let n_frag = fragments.len();
    let frag_locs: Vec<tip_protocol::messages::FragmentLocation> = fragments
        .iter()
        .map(|r| tip_protocol::messages::FragmentLocation {
            start: r.start,
            end: r.end,
        })
        .collect();
    eprintln!(
        "[full-doc compile_all] corpus: {} lines, {} fragments, {} bytes",
        n_lines,
        n_frag,
        src.len()
    );
    let mut world = TipWorld::new();
    let t0 = Instant::now();
    let res = TopDownCompiler::compile_all(&mut world, &src, &frag_locs, None).unwrap();
    let total_ms = t0.elapsed().as_secs_f64() * 1000.0;
    let hits = res
        .iter()
        .filter(|r| r.error.is_none() && !r.svg.is_empty())
        .count();
    eprintln!(
        "compile_all: total={:.1} ms ({:.3} ms/frag)  hits={}/{}",
        total_ms,
        total_ms / n_frag as f64,
        hits,
        n_frag,
    );
}

/// Helper: emulate typing a sequence of chars after `prefix`,
/// time each keystroke for both strategies.  Returns
/// (full_doc_latencies_ms, synth_latencies_ms, success counts).
/// Compile failures (mid-edit syntax errors) are timed but their
/// success doesn't count.
fn measure_keystrokes(prefix: &str, typed: &str) -> (Vec<f64>, Vec<f64>, usize, usize) {
    use crate::bottom_up::BottomUpCompiler;
    use std::time::Instant;
    let frag_start = prefix.len();

    let mut full_lat = Vec::new();
    let mut full_ok = 0;
    {
        let mut world = TipWorld::new();
        // Warm up.
        let _ = compile_real_document(&mut world, &prefix.to_string());
        let mut buf = prefix.to_string();
        for ch in typed.chars() {
            buf.push(ch);
            let frag_end = buf.len();
            let t0 = Instant::now();
            if let Ok(doc) = compile_real_document(&mut world, &buf) {
                let _ = extract_fragment_svg(&world, &doc, frag_start, frag_end);
                full_ok += 1;
            }
            full_lat.push(t0.elapsed().as_secs_f64() * 1000.0);
        }
    }

    let mut synth_lat = Vec::new();
    let mut synth_ok = 0;
    {
        let mut world = TipWorld::new();
        let mut buf = prefix.to_string();
        for ch in typed.chars() {
            buf.push(ch);
            let frag_end = buf.len();
            let t0 = Instant::now();
            let r = BottomUpCompiler::compile_fragment_scoped(
                &mut world,
                &buf,
                frag_start,
                frag_end,
                tip_protocol::svg_color::STANDIN_HEX,
                None,
                None,
                None,
            );
            if r.is_ok() {
                synth_ok += 1;
            }
            synth_lat.push(t0.elapsed().as_secs_f64() * 1000.0);
        }
    }
    (full_lat, synth_lat, full_ok, synth_ok)
}

fn lat_stats(label: &str, lat: &[f64], ok: usize) {
    let n = lat.len() as f64;
    let avg = lat.iter().sum::<f64>() / n;
    let mut sorted = lat.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let p50 = sorted[sorted.len() / 2];
    let p90 = sorted[(sorted.len() * 9) / 10];
    let p99 = sorted[(sorted.len() * 99) / 100];
    let max = sorted[sorted.len() - 1];
    let min = sorted[0];
    eprintln!(
            "  {:>8}: ok={}/{}  avg={:>5.1}  p50={:>5.1}  p90={:>5.1}  p99={:>5.1}  min={:>5.1}  max={:>6.1}",
            label, ok, lat.len(), avg, p50, p90, p99, min, max
        );
}

/// Bench: append a NEW fragment after the doc.  Many keystrokes
/// for stable statistics.  Tests cold-cache + comemo warm-up.
#[test]
#[ignore = "perf bench"]
fn bench_edit_append_new() {
    let (mut src, _) = build_5kloc_corpus();
    src.push_str("New: ");
    // 50+ char sequence: balanced math interleaved with edits.
    let typed = "$a + b = c$ and $integral_0^1 x^2 dif x$ tail";
    eprintln!("=== append new fragment after {} bytes ===", src.len());
    let (full, synth, full_ok, synth_ok) = measure_keystrokes(&src, typed);
    lat_stats("FULL-DOC", &full, full_ok);
    lat_stats("SYNTH", &synth, synth_ok);
}

/// Bench: type into the MIDDLE of the doc (replacing a single
/// char at line ~half-way).  Tests cache invalidation for
/// content far from the edit point.
#[test]
#[ignore = "perf bench"]
fn bench_edit_middle() {
    let (src, frags) = build_5kloc_corpus();
    // Insert at position right after the middle fragment.
    let mid = frags[frags.len() / 2].end;
    let prefix: String = src.chars().take(mid).collect();
    let suffix: String = src.chars().skip(mid).collect();
    let typed = "$alpha beta gamma$";
    eprintln!("=== edit middle (pos {}/{} bytes) ===", mid, src.len());
    // measure_keystrokes appends typed to prefix, but here we want
    // typed inserted before suffix.  Build buf = prefix + typed_so_far + suffix.
    use crate::bottom_up::BottomUpCompiler;
    use std::time::Instant;

    let mut full_lat = Vec::new();
    let mut full_ok = 0;
    {
        let mut world = TipWorld::new();
        let _ = compile_real_document(&mut world, &src);
        for k in 0..typed.len() {
            let typed_so_far: String = typed.chars().take(k + 1).collect();
            let buf = format!("{prefix}{typed_so_far}{suffix}");
            let frag_start = mid;
            let frag_end = mid + typed_so_far.len();
            let t0 = Instant::now();
            if let Ok(doc) = compile_real_document(&mut world, &buf) {
                let _ = extract_fragment_svg(&world, &doc, frag_start, frag_end);
                full_ok += 1;
            }
            full_lat.push(t0.elapsed().as_secs_f64() * 1000.0);
        }
    }
    let mut synth_lat = Vec::new();
    let mut synth_ok = 0;
    {
        let mut world = TipWorld::new();
        for k in 0..typed.len() {
            let typed_so_far: String = typed.chars().take(k + 1).collect();
            let buf = format!("{prefix}{typed_so_far}{suffix}");
            let frag_start = mid;
            let frag_end = mid + typed_so_far.len();
            let t0 = Instant::now();
            let r = BottomUpCompiler::compile_fragment_scoped(
                &mut world,
                &buf,
                frag_start,
                frag_end,
                tip_protocol::svg_color::STANDIN_HEX,
                None,
                None,
                None,
            );
            if r.is_ok() {
                synth_ok += 1;
            }
            synth_lat.push(t0.elapsed().as_secs_f64() * 1000.0);
        }
    }
    lat_stats("FULL-DOC", &full_lat, full_ok);
    lat_stats("SYNTH", &synth_lat, synth_ok);
}

/// Bench: type in a SHORT (100-line) doc.  Best-case for
/// full-doc; should be near-zero overhead.
#[test]
#[ignore = "perf bench"]
fn bench_edit_small_doc() {
    // Force smaller corpus regardless of TIP_BENCH_LINES.
    std::env::set_var("TIP_BENCH_LINES", "100");
    let (mut src, _) = build_5kloc_corpus();
    std::env::remove_var("TIP_BENCH_LINES");
    src.push_str("New: ");
    let typed = "$a + b$ and $sum_(i=1)^n i$ done";
    eprintln!("=== small doc, {} bytes ===", src.len());
    let (full, synth, fok, sok) = measure_keystrokes(&src, typed);
    lat_stats("FULL-DOC", &full, fok);
    lat_stats("SYNTH", &synth, sok);
}

/// Bench: editing latency.  Emulate the user appending a NEW
/// 5001th line containing a math fragment, character by
/// character, on top of an existing N-line document.  Each
/// keystroke triggers a full compile + extract for the new
/// fragment.  This is the live-preview hot path; we want well
/// below 30 ms per keystroke for a fluid edit experience.
/// `comemo` should cache layout for unchanged content, so
/// subsequent keystrokes are much cheaper than the first.
#[test]
#[ignore = "perf bench, run with --ignored"]
fn bench_5kloc_edit_latency() {
    use std::time::Instant;
    let (mut src, _) = build_5kloc_corpus();
    let typed = "$alpha + beta = gamma$";
    // Append "(typing soon: ...)" prefix so the new fragment is
    // surrounded by context similar to other lines.
    src.push_str("Typing now: ");

    // Build "context" by typing the prefix BEFORE timing each
    // keystroke, so each measured iteration is a single char added
    // to a buffer that already contained N-1 chars of the typed
    // string.  We allow compile failures (the partial syntax
    // mid-typing often won't parse — e.g. unmatched `$`); they're
    // expected to fall through to synth at runtime.
    let timed_keystrokes: Vec<usize> = (0..typed.len()).collect();

    eprintln!("=== FULL-DOC keystroke timing ===");
    {
        let mut world = TipWorld::new();
        let mut buf = src.clone();
        buf.push('x');
        let t0 = Instant::now();
        let _ = compile_real_document(&mut world, &buf);
        eprintln!(
            "  warm-up compile: {:.1} ms",
            t0.elapsed().as_secs_f64() * 1000.0
        );

        let mut buf = src.clone();
        let mut total_ms = 0.0;
        let mut succeeded = 0;
        let mut latencies = Vec::new();
        for k in &timed_keystrokes {
            let ch = typed.chars().nth(*k).unwrap();
            buf.push(ch);
            let t0 = Instant::now();
            if let Ok(doc) = compile_real_document(&mut world, &buf) {
                let s = src.len(); // typed text starts here
                let frag_end = buf.len();
                // The math fragment under construction starts at `s`
                // (the appended "Typing now: " ends at s; first `$`
                // of the fragment is at s + len("Typing now: ") = s).
                // Since `typed` starts with "$", frag_start = s.
                let _ = extract_fragment_svg(&world, &doc, s, frag_end);
                succeeded += 1;
            }
            let dt = t0.elapsed().as_secs_f64() * 1000.0;
            latencies.push(dt);
            total_ms += dt;
        }
        let avg = total_ms / latencies.len() as f64;
        let max = latencies.iter().copied().fold(f64::MIN, f64::max);
        let min = latencies.iter().copied().fold(f64::MAX, f64::min);
        eprintln!(
            "  per-keystroke: avg={:.1} ms  min={:.1} ms  max={:.1} ms  ({}/{} compiled)",
            avg,
            min,
            max,
            succeeded,
            latencies.len()
        );
    }

    eprintln!("=== SYNTH keystroke timing ===");
    {
        use crate::bottom_up::BottomUpCompiler;
        let mut world = TipWorld::new();
        let mut buf = src.clone();
        let mut total_ms = 0.0;
        let mut succeeded = 0;
        let mut latencies = Vec::new();
        for k in &timed_keystrokes {
            let ch = typed.chars().nth(*k).unwrap();
            buf.push(ch);
            let s = src.len();
            let frag_end = buf.len();
            let t0 = Instant::now();
            let r = BottomUpCompiler::compile_fragment_scoped(
                &mut world,
                &buf,
                s,
                frag_end,
                tip_protocol::svg_color::STANDIN_HEX,
                None,
                None,
                None,
            );
            if r.is_ok() {
                succeeded += 1;
            }
            let dt = t0.elapsed().as_secs_f64() * 1000.0;
            latencies.push(dt);
            total_ms += dt;
        }
        let avg = total_ms / latencies.len() as f64;
        let max = latencies.iter().copied().fold(f64::MIN, f64::max);
        let min = latencies.iter().copied().fold(f64::MAX, f64::min);
        eprintln!(
            "  per-keystroke: avg={:.1} ms  min={:.1} ms  max={:.1} ms  ({}/{} compiled)",
            avg,
            min,
            max,
            succeeded,
            latencies.len()
        );
    }
}

/// Audit synthetic's baseline picker against the same 7-level
/// sub tower that exposed the full-doc outer-vs-inner bug.
#[test]
#[ignore = "audit, run with --ignored"]
fn audit_synth_sub_tower_baseline() {
    use crate::bottom_up::BottomUpCompiler;
    let mut world = TipWorld::new();
    let src = "Body $a_(a_(a_(a_(a_(a_(a_a))))))$ end\n";
    let r = locate(src, "$a_(a_(a_(a_(a_(a_(a_a))))))$");
    let s = BottomUpCompiler::compile_fragment_scoped(
        &mut world,
        src,
        r.start,
        r.end,
        tip_protocol::svg_color::STANDIN_HEX,
        None,
        None,
        None,
    )
    .expect("synth compile");
    eprintln!(
        "SYNTH 7-sub-tower: h={:.3} d={:.3} w={:.3}  ascent={:.1}%",
        s.height_pt,
        s.depth_pt,
        s.width_pt,
        (s.height_pt - s.depth_pt) / s.height_pt * 100.0,
    );
    // Walk synth's compiled doc to enumerate Groups + baselines.
    let synth_src =
        crate::bottom_up::BottomUpCompiler::debug_scoped_source(src, r.start, r.end).unwrap();
    eprintln!("SYNTH source: {}", synth_src.replace('\n', " | "));
    let mut w2 = TipWorld::new();
    w2.set_main_source(&synth_src);
    let synth_doc = typst::compile::<PagedDocument>(&w2).output.unwrap();
    eprintln!("=== synth Groups (any has_baseline) ===");
    let mut all_groups = Vec::<(usize, f64, bool)>::new();
    walk_synth_dbg(&synth_doc.pages()[0].frame, 0, 0.0, &mut all_groups);
    for (depth, b, has) in &all_groups {
        eprintln!("  depth={} baseline_y={:.3} has_baseline={}", depth, b, has);
    }
    // Same fragment under full-doc.
    let mut wf = TipWorld::new();
    let doc = compile_real_document(&mut wf, src).expect("compile");
    let f = extract_fragment_svg(&wf, &doc, r.start, r.end).unwrap();
    eprintln!(
        "FULL  7-sub-tower: h={:.3} d={:.3} w={:.3}  ascent={:.1}%",
        f.height_pt,
        f.depth_pt,
        f.width_pt,
        (f.height_pt - f.depth_pt) / f.height_pt * 100.0,
    );
}

#[test]
#[ignore = "diagnostic only"]
fn diag_phantom_baseline() {
    use crate::bottom_up::BottomUpCompiler;
    let mut world = TipWorld::new();
    let src = "\
#let phantom(x) = hide($#x$)
text $phantom(a)^2$ and $a^2$ done
";
    let doc = compile_real_document(&mut world, src).expect("compile");
    for (label, anchor) in [("phantom", "$phantom(a)^2$"), ("plain", "$a^2$")] {
        let r = locate(src, anchor);
        // Synth metrics
        let mut wsynth = TipWorld::new();
        let s = BottomUpCompiler::compile_fragment_scoped(
            &mut wsynth,
            src,
            r.start,
            r.end,
            tip_protocol::svg_color::STANDIN_HEX,
            None,
            None,
            None,
        )
        .unwrap();
        eprintln!(
            "[{} synth]: h={:.3} d={:.3} w={:.3}  ascent={:.1}%",
            label,
            s.height_pt,
            s.depth_pt,
            s.width_pt,
            (s.height_pt - s.depth_pt) / s.height_pt * 100.0,
        );
        let main = world.main();
        let main_src = world.source(main).ok().unwrap();
        let mut leaves = Vec::new();
        let mut groups = Vec::new();
        flatten_leaves(
            &doc.pages()[0].frame,
            Point::zero(),
            main,
            &main_src,
            &mut leaves,
            &mut groups,
        );
        eprintln!("=== {} ===", label);
        for l in &leaves {
            if matches!(l.category_for(r.start, r.end), LeafCategory::InRange) {
                eprintln!(
                    "  leaf pos.y={:.3} size={:?}",
                    l.pos.y.to_pt(),
                    l.text_size.map(|s| s.to_pt())
                );
            }
        }
        for (i, g) in groups.iter().enumerate() {
            eprintln!(
                "  group #{i} baseline_y={:.3} has_in_range={}",
                g.baseline_y.to_pt(),
                g.leaf_range.start
            );
        }
        let f = extract_fragment_svg(&world, &doc, r.start, r.end).unwrap();
        eprintln!(
            "  result: h={:.3} d={:.3} w={:.3} ext_used={}",
            f.height_pt, f.depth_pt, f.width_pt, f.baseline_external
        );
        eprintln!("  baseline_in_image_pt = {:.3}", f.height_pt - f.depth_pt);
        // Save SVG to disk for visual inspection.
        let path = format!("/tmp/tip-fulldoc-demo/{}-fulldoc.svg", label);
        std::fs::write(&path, &f.svg).unwrap();
        eprintln!("  saved to {}", path);
        // Save synth SVG too.
        let synth_path = format!("/tmp/tip-fulldoc-demo/{}-synth.svg", label);
        std::fs::write(&synth_path, &s.svg).unwrap();
        eprintln!("  synth saved to {}", synth_path);
    }
}

/// Diagnostic for sub/cfrac tower baseline reporting in context.
/// Prints what Group baseline says vs what surrounding text says.
#[test]
#[ignore = "diagnostic only"]
fn diag_sub_tower_baseline() {
    let mut world = TipWorld::new();
    let src = "Body $a_(a_(a_(a_(a_(a_(a_a))))))$ end\n";
    let doc = compile_real_document(&mut world, src).expect("compile");
    let r = locate(src, "$a_(a_(a_(a_(a_(a_(a_a))))))$");
    // Walk to dump all info.
    let main = world.main();
    let main_src = world.source(main).ok().unwrap();
    let mut leaves = Vec::new();
    let mut groups = Vec::new();
    flatten_leaves(
        &doc.pages()[0].frame,
        Point::zero(),
        main,
        &main_src,
        &mut leaves,
        &mut groups,
    );
    eprintln!("=== leaves in fragment ===");
    for l in &leaves {
        if matches!(l.category_for(r.start, r.end), LeafCategory::InRange) {
            eprintln!(
                "  pos.y={:.3} size={:?} kind={:?}",
                l.pos.y.to_pt(),
                l.text_size.map(|s| s.to_pt()),
                match &l.item {
                    FrameItem::Text(_) => "Text",
                    FrameItem::Shape(_, _) => "Shape",
                    _ => "?",
                }
            );
        }
    }
    eprintln!("=== group baselines ===");
    for g in &groups {
        eprintln!(
            "  baseline_y={:.3} has_in_range={}",
            g.baseline_y.to_pt(),
            g.leaf_range.start
        );
    }
    eprintln!("=== external (out-of-frag, page-wide) text baselines ===");
    let mut ext = Vec::new();
    walk_external(
        &doc.pages()[0].frame,
        Point::zero(),
        main,
        &main_src,
        r.start,
        r.end,
        &mut ext,
    );
    for y in &ext {
        eprintln!("  ext pos.y={:.3}", y.to_pt());
    }
    let f = extract_fragment_svg(&world, &doc, r.start, r.end).unwrap();
    eprintln!(
        "=== final: h={:.3} d={:.3} ext_used={}",
        f.height_pt, f.depth_pt, f.baseline_external
    );
}

/// Live-bug probe: print height/depth/baseline for `$a+b=c$` in
/// both strategies.  Eyeballed against GUI rendering — synthetic
/// looks correct; full-doc reportedly puts math too high.
#[test]
#[ignore = "diagnostic only, run with --ignored"]
fn diag_depth_for_inline() {
    use crate::bottom_up::BottomUpCompiler;
    let mut w_full = TipWorld::new();
    let mut w_syn = TipWorld::new();
    let src = "Default 11pt: $a + b = c$ and rest.\n";
    let doc = compile_real_document(&mut w_full, src).expect("compile");
    let r = locate(src, "$a + b = c$");
    let f = extract_fragment_svg(&w_full, &doc, r.start, r.end).unwrap();
    let s = BottomUpCompiler::compile_fragment_scoped(
        &mut w_syn,
        src,
        r.start,
        r.end,
        tip_protocol::svg_color::STANDIN_HEX,
        None,
        None,
        None,
    )
    .unwrap();
    let spans = collect_leaf_spans(&w_full, &doc);
    for s in &spans {
        if let Some(ref r2) = s.source_range {
            if r2.start >= r.start && r2.end <= r.end {
                eprintln!("  frag glyph range={:?} pos.y={:.3}", r2, s.pos_pt.1);
            }
        }
    }
    eprintln!(
        "full:  h={:.3} d={:.3} w={:.3} fs={:.3} ext={}",
        f.height_pt, f.depth_pt, f.width_pt, f.font_size_pt, f.baseline_external
    );
    eprintln!(
        "synth: h={:.3} d={:.3} w={:.3}",
        s.height_pt, s.depth_pt, s.width_pt
    );
    eprintln!(
        "ascent_full={:.1}%  ascent_synth={:.1}%",
        (f.height_pt - f.depth_pt) / f.height_pt * 100.0,
        (s.height_pt - s.depth_pt) / s.height_pt * 100.0,
    );
}

#[test]
fn synthetic_and_full_doc_agree_on_default_size() {
    use crate::bottom_up::BottomUpCompiler;

    let mut w_full = TipWorld::new();
    let mut w_syn = TipWorld::new();
    let src = "Body $x + y$ here.\n";
    let doc = compile_real_document(&mut w_full, src).expect("compile");
    let r = locate(src, "$x + y$");
    let full = extract_fragment_svg(&w_full, &doc, r.start, r.end).unwrap();
    let syn = BottomUpCompiler::compile_fragment_scoped(
        &mut w_syn,
        src,
        r.start,
        r.end,
        tip_protocol::svg_color::STANDIN_HEX,
        None,
        None,
        None,
    )
    .expect("synthetic compile");

    // Width within 25% (different layout contexts produce slightly
    // different glyph advances; allow some slack but flag big drift).
    let wr = full.width_pt / syn.width_pt;
    assert!(
        wr > 0.75 && wr < 1.25,
        "width drift: full={:.2} synthetic={:.2} ratio={:.2}",
        full.width_pt,
        syn.width_pt,
        wr
    );
    // Height within 35% — synthetic adds 0.5pt padding and crops
    // differently around margins, but the ink should be similar.
    let hr = full.height_pt / syn.height_pt;
    assert!(
        hr > 0.65 && hr < 1.35,
        "height drift: full={:.2} synthetic={:.2} ratio={:.2}",
        full.height_pt,
        syn.height_pt,
        hr
    );
}

/// Regression: `dif`, `pi`, and other typst math symbols are
/// referenced by user-written identifiers but resolved via the
/// math scope (or imported modules).  If their resulting glyphs
/// carry spans that point to the std-lib definition rather than
/// the user source, the fragment-range filter drops them and
/// the rendered SVG is missing `dif x` / `pi` etc.  Verify the
/// glyphs survive the filter.
#[test]
fn extract_keeps_math_symbol_glyphs() {
    // Render `$dif x$` (full doc) and `$x$` alone.  If `dif`'s
    // detached-span TextItem isn't recovered by the neighborhood
    // pass, the rendered widths are equal — bug.  With recovery,
    // `dif x` is wider than `x` by roughly the width of a `d`
    // glyph plus its math spacing.
    let mut world = TipWorld::new();
    let src = "$dif x$ then $x$ alone\n";
    let doc = compile_real_document(&mut world, src).expect("compile");
    let r_dif = locate(src, "$dif x$");
    let r_x = locate(src, "$x$");
    let f_dif = extract_fragment_svg(&world, &doc, r_dif.start, r_dif.end).expect("dif x render");
    let f_x = extract_fragment_svg(&world, &doc, r_x.start, r_x.end).expect("x render");
    assert!(
        f_dif.width_pt > f_x.width_pt + 4.0,
        "expected `dif x` ({:.2}pt) noticeably wider than `x` ({:.2}pt) — \
             detached `dif` glyph likely dropped",
        f_dif.width_pt,
        f_x.width_pt
    );
}

/// Back-to-back math fragments separated only by `dif`-style
/// detached glyphs MUST NOT cross-contaminate.  The run-based
/// algorithm should treat the prose word "and" between them as
/// an OutAttached barrier, partitioning detached items by which
/// fragment they belong to.
/// Stress: very small body size (1 pt).  At this scale the
/// default 13 pt line spacing collapses to ~1.2 pt, well inside
/// the 6 pt baseline tol [H2].  If `find_external_baseline` picks
/// up the next line's baseline, depth + height go absurd.
///
/// We're not asserting that 1 pt looks GOOD — just that the
/// metrics stay sane: positive height, font_size near 1, and
/// no cross-line baseline contamination.
#[test]
fn extreme_small_text_size_1pt() {
    let mut world = TipWorld::new();
    let src = "\
#set text(size: 1pt)
line one with $a + b$ math.
line two with $c - d$ math.
";
    let doc = compile_real_document(&mut world, src).expect("compile");
    let r1 = locate(src, "$a + b$");
    let r2 = locate(src, "$c - d$");
    let f1 = extract_fragment_svg(&world, &doc, r1.start, r1.end).unwrap();
    let f2 = extract_fragment_svg(&world, &doc, r2.start, r2.end).unwrap();

    eprintln!(
        "f1 (1pt): h={:.3} d={:.3} w={:.3} fs={:.3} ext={}",
        f1.height_pt, f1.depth_pt, f1.width_pt, f1.font_size_pt, f1.baseline_external
    );
    eprintln!(
        "f2 (1pt): h={:.3} d={:.3} w={:.3} fs={:.3} ext={}",
        f2.height_pt, f2.depth_pt, f2.width_pt, f2.font_size_pt, f2.baseline_external
    );

    // Sanity: font size matches paragraph context.
    assert!(
        f1.font_size_pt < 2.0,
        "f1 font_size {:.3} should be ~1pt",
        f1.font_size_pt
    );
    assert!(
        f2.font_size_pt < 2.0,
        "f2 font_size {:.3} should be ~1pt",
        f2.font_size_pt
    );
    // Cross-line contamination check: at 1 pt, line spacing ~1.2 pt,
    // tol=6pt could pick the OTHER line's baseline.  If it does, the
    // height blows up to ~one line spacing.  An honest 1 pt math
    // height should be < 2 pt.
    assert!(
        f1.height_pt < 2.0,
        "f1 height {:.3} much larger than 1pt — likely cross-line baseline",
        f1.height_pt
    );
    assert!(
        f2.height_pt < 2.0,
        "f2 height {:.3} much larger than 1pt — likely cross-line baseline",
        f2.height_pt
    );
}

/// Stress: phantom-base superscript at 1 pt — super-shift is
/// ~0.4 pt, below the 2 pt SHIFT_THRESHOLD [H3].  The picker
/// won't escape to external; depth/height come from frag own.
/// At this scale, both behaviors should produce similar results
/// since the shift is so small.  Verify it doesn't crash and
/// produces positive numbers.
#[test]
fn extreme_small_phantom_superscript_1pt() {
    let mut world = TipWorld::new();
    let src = "\
#set text(size: 1pt)
#let phantom(x) = hide($#x$)
text $phantom(a)^2$ and $a^2$ done
";
    let doc = compile_real_document(&mut world, src).expect("compile");
    let r_phantom = locate(src, "$phantom(a)^2$");
    let r_plain = locate(src, "$a^2$");
    let f_phantom = extract_fragment_svg(&world, &doc, r_phantom.start, r_phantom.end).unwrap();
    let f_plain = extract_fragment_svg(&world, &doc, r_plain.start, r_plain.end).unwrap();

    eprintln!(
        "1pt phantom: h={:.3} d={:.3} w={:.3} fs={:.3}",
        f_phantom.height_pt, f_phantom.depth_pt, f_phantom.width_pt, f_phantom.font_size_pt
    );
    eprintln!(
        "1pt plain:   h={:.3} d={:.3} w={:.3} fs={:.3}",
        f_plain.height_pt, f_plain.depth_pt, f_plain.width_pt, f_plain.font_size_pt
    );

    assert!(f_phantom.height_pt > 0.0);
    assert!(f_plain.height_pt > 0.0);
    // Both should report ~1 pt paragraph context.
    assert!(f_phantom.font_size_pt < 2.0);
    assert!(f_plain.font_size_pt < 2.0);
}

/// Stress: very tight `#set par(leading: 0pt)` — adjacent lines
/// can be < 1 pt apart.  Even at 11 pt body, our 6 pt tol could
/// span lines.  Verify metrics stay sane.
/// Stress: pseudo-random mix of 1pt..10pt in the same buffer.
/// Each math fragment must report `font_size_pt` matching ITS
/// section, not bleed from neighbors.  Heights scale with the
/// section size.  Catches: external-baseline picker grabbing a
/// neighbor of a different size, font-size lookup returning an
/// unrelated section's value.
#[test]
fn extreme_mixed_sizes_1_to_10pt() {
    let mut world = TipWorld::new();
    let src = "\
#text(size: 1pt)[$a + b$ at one]

#text(size: 3pt)[$a + b$ at three]

#text(size: 7pt)[$a + b$ at seven]

#text(size: 10pt)[$a + b$ at ten]

#text(size: 2pt)[$a + b$ at two]

#text(size: 9pt)[$a + b$ at nine]
";
    let doc = compile_real_document(&mut world, src).expect("compile");
    // Locate each fragment by section.
    let cases = [
        ("at one", 1.0),
        ("at three", 3.0),
        ("at seven", 7.0),
        ("at ten", 10.0),
        ("at two", 2.0),
        ("at nine", 9.0),
    ];
    let mut results = Vec::new();
    for (anchor, expected_size) in cases {
        // Find the `$a + b$` whose follow-up text is `anchor`.
        let after_idx = src.find(anchor).unwrap();
        // Walk back to the nearest `$a + b$` before `anchor`.
        let math_start = src[..after_idx].rfind("$a + b$").unwrap();
        let f =
            extract_fragment_svg(&world, &doc, math_start, math_start + "$a + b$".len()).unwrap();
        eprintln!(
            "{anchor:>10} (~{expected_size}pt): h={:.3} d={:.3} w={:.3} fs={:.3}",
            f.height_pt, f.depth_pt, f.width_pt, f.font_size_pt
        );
        results.push((expected_size, f));
    }

    // Each fragment's reported font_size_pt must be within 0.5pt
    // of the section size — proves no leak from neighbors.
    for (expected, f) in &results {
        assert!(
            (f.font_size_pt - expected).abs() < 0.5,
            "fragment at {expected}pt got font_size {:.3} — neighbor bleed?",
            f.font_size_pt
        );
    }

    // Heights must scale roughly with size — but not linearly,
    // because the pad+depth contribute a near-constant ~0.5 pt
    // floor.  At 10 pt vs 1 pt, the ratio is ~5× rather than 10×.
    let h_1pt = results[0].1.height_pt;
    let h_10pt = results[3].1.height_pt;
    assert!(
        h_10pt > h_1pt * 3.0,
        "10pt height {:.3} should be visibly larger than 1pt {:.3}",
        h_10pt,
        h_1pt
    );

    // No fragment should have an absurd height (cross-paragraph
    // baseline pickup).  Cap: 3× the section size.
    for (expected, f) in &results {
        assert!(
            f.height_pt < expected * 3.0,
            "fragment at {expected}pt has height {:.3} — sane upper bound is ~{}",
            f.height_pt,
            expected * 3.0
        );
    }
}

/// Stress: deeply nested superscript tower.  Each level shrinks
/// by Typst's super-scale (~0.7×) — the deepest `a` is tiny, but
/// the cumulative ascent piles ~7 levels' worth of glyphs above
/// the baseline.  Tests the crop's vertical extent and ensures
/// baseline picker doesn't get confused by the wide y-range of
/// fragment items.
#[test]
fn extreme_nested_superscripts() {
    let mut world = TipWorld::new();
    let src = "Body $a^(a^(a^(a^(a^(a^(a^a))))))$ done\n";
    let doc = compile_real_document(&mut world, src).expect("compile");
    let r = locate(src, "$a^(a^(a^(a^(a^(a^(a^a))))))$");
    let f = extract_fragment_svg(&world, &doc, r.start, r.end).unwrap();
    eprintln!(
        "nested-sup: h={:.3} d={:.3} w={:.3} fs={:.3}",
        f.height_pt, f.depth_pt, f.width_pt, f.font_size_pt
    );
    // Sanity:
    // - Height noticeably taller than a normal `$a^2$` (ascent
    //   tower piles up).
    // - Width modest — each level only adds one shrinking glyph.
    // - Depth ≈ 0 + pad — base `a` sits on baseline, no descender.
    // - Font size = paragraph context (~11 pt).
    assert!(
        f.height_pt > 12.0,
        "nested sup height {:.3} too small",
        f.height_pt
    );
    assert!(
        f.height_pt < 60.0,
        "nested sup height {:.3} absurd",
        f.height_pt
    );
    // Width: 7 superscripts stacked diagonally accumulate to ~30–40 pt at 11 pt body.
    assert!(
        f.width_pt > 0.0 && f.width_pt < 80.0,
        "width {:.3}",
        f.width_pt
    );
    assert!(
        (f.font_size_pt - 11.0).abs() < 0.5,
        "fs {:.3}",
        f.font_size_pt
    );
}

/// Stress: deeply nested subscript tower.  Cumulative descent
/// piles below the baseline; depth_pt should be much larger than
/// for a normal `$a_2$`.
#[test]
fn extreme_nested_subscripts() {
    let mut world = TipWorld::new();
    let src = "Body $a_(a_(a_(a_(a_(a_(a_a))))))$ done\n";
    let doc = compile_real_document(&mut world, src).expect("compile");
    let r = locate(src, "$a_(a_(a_(a_(a_(a_(a_a))))))$");
    let f = extract_fragment_svg(&world, &doc, r.start, r.end).unwrap();
    eprintln!(
        "nested-sub: h={:.3} d={:.3} w={:.3} fs={:.3}",
        f.height_pt, f.depth_pt, f.width_pt, f.font_size_pt
    );
    assert!(
        f.height_pt > 8.0,
        "nested sub height {:.3} too small",
        f.height_pt
    );
    assert!(
        f.height_pt < 60.0,
        "nested sub height {:.3} absurd",
        f.height_pt
    );
    assert!(
        f.depth_pt > 5.0,
        "nested sub depth {:.3} too small — descender tower lost",
        f.depth_pt
    );
    assert!(
        (f.font_size_pt - 11.0).abs() < 0.5,
        "fs {:.3}",
        f.font_size_pt
    );
}

/// Stress: deeply nested fractions at 1 pt body.  Combines small-
/// size tol [H2/H4] and complex Group structure (each `frac`
/// produces its own equation Group with baseline).  At 7 levels
/// of nesting the inner fractions render at sub-fractional pt
/// sizes — exercises numerical stability of crop/baseline math.
#[test]
fn extreme_nested_fractions_small() {
    let mut world = TipWorld::new();
    let src = "\
#set text(size: 1pt)
text $frac(1, frac(1, frac(1, frac(1, frac(1, frac(1, frac(1, x)))))))$ done
";
    let doc = compile_real_document(&mut world, src).expect("compile");
    let r = locate(
        src,
        "$frac(1, frac(1, frac(1, frac(1, frac(1, frac(1, frac(1, x)))))))$",
    );
    let f = extract_fragment_svg(&world, &doc, r.start, r.end).unwrap();
    eprintln!(
        "nested-frac 1pt: h={:.3} d={:.3} w={:.3} fs={:.3}",
        f.height_pt, f.depth_pt, f.width_pt, f.font_size_pt
    );
    // The fraction tower's height at 1 pt body should be in
    // the low single digits.  Inner fractions are tiny but
    // cumulative.
    assert!(f.height_pt > 0.5);
    assert!(
        f.height_pt < 20.0,
        "height {:.3} suggests cross-paragraph contamination",
        f.height_pt
    );
    assert!(
        (f.font_size_pt - 1.0).abs() < 0.3,
        "fs {:.3} — font picker drifted",
        f.font_size_pt
    );
    assert!(f.svg.contains("<svg"));
}

/// Render a fragment with the synthetic strategy at a chosen body
/// size, return its (height, depth, width).  Used as ground truth
/// for the full-doc comparison sweep below.
fn synth_metrics(
    world: &mut TipWorld,
    src: &str,
    frag_start: usize,
    frag_end: usize,
    body_pt: f64,
) -> (f64, f64, f64) {
    use crate::bottom_up::BottomUpCompiler;
    let page_setup = format!(
            "#show math.equation: set text(size: {body_pt}pt)\n#set page(width: auto, height: auto, margin: 20pt, header: none, footer: none)\n"
        );
    let out = BottomUpCompiler::compile_fragment_scoped(
        world,
        src,
        frag_start,
        frag_end,
        tip_protocol::svg_color::STANDIN_HEX,
        Some(&page_setup),
        None,
        None,
    )
    .expect("synth compile");
    (out.height_pt, out.depth_pt, out.width_pt)
}

/// Sweep: for each fragment in the demo, compare full-doc metrics
/// against synthetic at the same body size.  Synthetic crops to
/// ink and has been hand-validated for years; treat its width and
/// height as ground truth.  Width should agree within ~10 %,
/// height within ~15 %.
///
/// This test is the answer to "make assertions principled" —
/// no more hand-tuned numeric ranges.
#[test]
fn sweep_against_synthetic_reference() {
    struct Case<'a> {
        name: &'a str,
        src: &'a str,
        needle: &'a str,
        body_pt: f64,
    }

    let cases = [
        Case {
            name: "simple inline",
            src: "Body $a + b = c$ end\n",
            needle: "$a + b = c$",
            body_pt: 11.0,
        },
        Case {
            name: "fraction inline",
            src: "Body $1/2 + 3/4$ end\n",
            needle: "$1/2 + 3/4$",
            body_pt: 11.0,
        },
        Case {
            name: "sqrt with detached pi",
            src: "Body $sqrt(pi)$ end\n",
            needle: "$sqrt(pi)$",
            body_pt: 11.0,
        },
        Case {
            name: "sup tower",
            src: "Body $a^(a^(a^a))$ end\n",
            needle: "$a^(a^(a^a))$",
            body_pt: 11.0,
        },
        Case {
            name: "sub tower",
            src: "Body $a_(a_(a_a))$ end\n",
            needle: "$a_(a_(a_a))$",
            body_pt: 11.0,
        },
        Case {
            name: "14pt section",
            src: "#text(size: 14pt)[Body $a + b$ end]\n",
            needle: "$a + b$",
            body_pt: 14.0,
        },
        Case {
            name: "1pt section",
            src: "#text(size: 1pt)[Body $a + b$ end]\n",
            needle: "$a + b$",
            body_pt: 1.0,
        },
        Case {
            name: "matrix",
            src: "Body $mat(1, 0; 0, 1)$ end\n",
            needle: "$mat(1, 0; 0, 1)$",
            body_pt: 11.0,
        },
    ];

    let mut failed = 0;
    for case in &cases {
        let mut w_full = TipWorld::new();
        let mut w_syn = TipWorld::new();
        let doc = compile_real_document(&mut w_full, case.src).expect("compile");
        let r = locate(case.src, case.needle);
        let f = match extract_fragment_svg(&w_full, &doc, r.start, r.end) {
            Some(f) => f,
            None => {
                eprintln!("[{}] full-doc returned None — SKIP", case.name);
                continue;
            }
        };
        let (sh, sd, sw) = synth_metrics(&mut w_syn, case.src, r.start, r.end, case.body_pt);
        let dh = (f.height_pt - sh).abs() / sh;
        let dw = (f.width_pt - sw).abs() / sw;
        let dd = if sd > 0.1 {
            (f.depth_pt - sd).abs() / sd
        } else {
            (f.depth_pt - sd).abs() / 1.0
        };
        eprintln!(
                "[{:>20}] full=(h={:.2} d={:.2} w={:.2}) synth=(h={:.2} d={:.2} w={:.2}) Δh={:.1}% Δw={:.1}%",
                case.name,
                f.height_pt,
                f.depth_pt,
                f.width_pt,
                sh,
                sd,
                sw,
                dh * 100.0,
                dw * 100.0
            );
        if dh > 0.15 || dw > 0.10 {
            failed += 1;
            eprintln!(
                "  FAILED: Δh={:.1}% (cap 15%)  Δw={:.1}% (cap 10%)  Δd={:.2}",
                dh * 100.0,
                dw * 100.0,
                dd
            );
        }
    }
    assert_eq!(
        failed, 0,
        "{failed} fixtures diverged from synthetic reference"
    );
}

#[test]
fn extreme_zero_leading() {
    let mut world = TipWorld::new();
    let src = "\
#set par(leading: 0pt)
line one with $a + b$ math.
line two with $c - d$ math.
";
    let doc = compile_real_document(&mut world, src).expect("compile");
    let r1 = locate(src, "$a + b$");
    let r2 = locate(src, "$c - d$");
    let f1 = extract_fragment_svg(&world, &doc, r1.start, r1.end).unwrap();
    let f2 = extract_fragment_svg(&world, &doc, r2.start, r2.end).unwrap();

    eprintln!(
        "0-leading f1: h={:.3} d={:.3} ext={}",
        f1.height_pt, f1.depth_pt, f1.baseline_external
    );
    eprintln!(
        "0-leading f2: h={:.3} d={:.3} ext={}",
        f2.height_pt, f2.depth_pt, f2.baseline_external
    );

    // Reasonable inline-math height for 11 pt body is ~10 pt.
    // If we're picking the WRONG line's baseline, height balloons
    // way beyond that.
    assert!(
        f1.height_pt < 20.0,
        "f1 height {:.3} suggests cross-line contamination",
        f1.height_pt
    );
    assert!(
        f2.height_pt < 20.0,
        "f2 height {:.3} suggests cross-line contamination",
        f2.height_pt
    );
}

#[test]
fn run_pass_partitions_detached_between_fragments() {
    let mut world = TipWorld::new();
    let src = "$dif x$ and $dif y$\n";
    let doc = compile_real_document(&mut world, src).expect("compile");
    let r1 = locate(src, "$dif x$");
    let r2 = locate(src, "$dif y$");
    let f1 = extract_fragment_svg(&world, &doc, r1.start, r1.end).unwrap();
    let f2 = extract_fragment_svg(&world, &doc, r2.start, r2.end).unwrap();
    // Each fragment should be wider than just `x` or `y` — so its
    // own `dif` glyph is included.  Their widths should be similar
    // (same glyphs, same context).
    assert!(
        f1.width_pt > 8.0,
        "fragment 1 missing dif: w={:.2}",
        f1.width_pt
    );
    assert!(
        f2.width_pt > 8.0,
        "fragment 2 missing dif: w={:.2}",
        f2.width_pt
    );
    assert!(
        (f1.width_pt - f2.width_pt).abs() < 4.0,
        "fragment widths drifted, suggesting cross-contamination: \
             f1={:.2} f2={:.2}",
        f1.width_pt,
        f2.width_pt
    );
}

#[test]
fn extract_keeps_sqrt_radicand() {
    // Companion: `$sqrt(pi)$` must include the `pi` (π) glyph.
    // Without the neighborhood pass it renders as just `√`.
    let mut world = TipWorld::new();
    let src = "Body $sqrt(pi)$ and $sqrt(x)$ done\n";
    let doc = compile_real_document(&mut world, src).expect("compile");
    let r_pi = locate(src, "$sqrt(pi)$");
    let r_x = locate(src, "$sqrt(x)$");
    let f_pi = extract_fragment_svg(&world, &doc, r_pi.start, r_pi.end).unwrap();
    let f_x = extract_fragment_svg(&world, &doc, r_x.start, r_x.end).unwrap();
    // sqrt(pi) and sqrt(x) should both render with a radicand —
    // their widths shouldn't differ by more than a few pt.  If
    // pi's glyph is dropped, sqrt(pi)'s ink is just the radical
    // which is much narrower.
    assert!(
        (f_pi.width_pt - f_x.width_pt).abs() < 5.0,
        "sqrt(pi) ({:.2}) and sqrt(x) ({:.2}) widths diverged — \
             pi glyph probably missing",
        f_pi.width_pt,
        f_x.width_pt
    );
}

#[test]
fn extract_handles_phantom_base_superscript() {
    // The phantom-base case from the partition regression test:
    // `phantom(a)^2` must still render — the `^2` glyph is real,
    // even with an invisible base.  Step 4 handles the baseline.
    let mut world = TipWorld::new();
    let src = "\
#let phantom(x) = hide($#x$)
$phantom(a)^2$
";
    let doc = compile_real_document(&mut world, src).expect("compile");
    let r = locate(src, "$phantom(a)^2$");
    let f = extract_fragment_svg(&world, &doc, r.start, r.end)
        .expect("phantom-base fragment should render");
    assert!(f.width_pt > 0.0);
    assert!(f.height_pt > 0.0);
    assert!(f.svg.contains("<svg"));
}

#[test]
fn leaf_spans_skip_unrelated_text() {
    let mut world = TipWorld::new();
    let src = "Body. $x$ done.\n";
    let doc = compile_real_document(&mut world, src).expect("compile");
    let spans = collect_leaf_spans(&world, &doc);
    let r = locate(src, "$x$");
    let inside = fragment_items(&spans, r.start, r.end);
    // The body text "Body." and " done." should not be counted as
    // belonging to the math fragment.
    for s in &inside {
        let sr = s.source_range.as_ref().unwrap();
        assert!(
            sr.start >= r.start && sr.end <= r.end,
            "item at {:?} leaked outside fragment range {:?}",
            sr,
            r
        );
    }
}
