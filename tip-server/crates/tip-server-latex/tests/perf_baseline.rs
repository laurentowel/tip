//! Perf baseline: measure tip-server-latex wall-clock on realistic inputs.
//!
//! Runs only when latex + dvisvgm are on PATH. Prints timings to stderr so
//! `cargo test -- --nocapture` shows them.

use std::time::Instant;

use testkit::server::TestServer;
use tip_protocol::messages::*;

fn bin_path() -> String {
    let mut path = std::env::current_exe().unwrap().parent().unwrap().parent().unwrap().to_path_buf();
    path.push("tip-server-latex");
    path.to_str().unwrap().to_string()
}

fn tools_available() -> bool {
    fn which(c: &str) -> bool {
        std::env::var_os("PATH")
            .map(|p| std::env::split_paths(&p).any(|p| p.join(c).is_file()))
            .unwrap_or(false)
    }
    which("latex") && which("dvisvgm")
}

fn bench(label: &str, preamble: &str, fragment_src: &str, fragments: Vec<(usize, usize)>) {
    let n = fragments.len();
    let mut server = TestServer::spawn(&bin_path());
    server.request(&RequestMessage {
        id: 1,
        request: Request::Sync(SyncParams {
            uri: "/tmp/bench.tex".into(),
            content: fragment_src.into(),
        }),
    });

    let t0 = Instant::now();
    let resp = server.request(&RequestMessage {
        id: 2,
        request: Request::CompileFragments(CompileFragmentsParams {
            uri: "/tmp/bench.tex".into(),
            fragments: fragments
                .iter()
                .map(|(s, e)| FragmentLocation { start: *s, end: *e })
                .collect(),
            color: "#000000".into(),
            page_setup: None,
            preamble: Some(preamble.into()),
        }),
    });
    let elapsed = t0.elapsed();

    match &resp.result {
        ResponseResult::Fragments { fragments: results } => {
            let ok = results.iter().filter(|f| f.error.is_none()).count();
            eprintln!(
                "[{:<18}] {:2} frags → {:3} OK, {:3} err, total {:>6.1} ms, per-frag {:>5.1} ms",
                label,
                n,
                ok,
                n - ok,
                elapsed.as_millis() as f64,
                (elapsed.as_millis() as f64) / (n as f64)
            );
        }
        other => panic!("{}: unexpected result: {:?}", label, other),
    }
}

/// Same fragments compiled twice in sequence — measures amortized cost
/// when the server process is warm (no reinit).
fn bench_warm(label: &str, preamble: &str, src: &str, frags: Vec<(usize, usize)>) {
    let n = frags.len();
    let mut server = TestServer::spawn(&bin_path());
    server.request(&RequestMessage {
        id: 1,
        request: Request::Sync(SyncParams {
            uri: "/tmp/bench.tex".into(),
            content: src.into(),
        }),
    });
    let mk = || CompileFragmentsParams {
        uri: "/tmp/bench.tex".into(),
        fragments: frags.iter().map(|(s, e)| FragmentLocation { start: *s, end: *e }).collect(),
        color: "#000000".into(),
        page_setup: None,
        preamble: Some(preamble.into()),
    };
    let t0 = Instant::now();
    server.request(&RequestMessage { id: 2, request: Request::CompileFragments(mk()) });
    let cold = t0.elapsed();
    let t0 = Instant::now();
    server.request(&RequestMessage { id: 3, request: Request::CompileFragments(mk()) });
    let warm = t0.elapsed();
    eprintln!(
        "[{:<18}] {} frags: cold {:.0} ms, warm {:.0} ms (Δ {:+.0})",
        label, n, cold.as_millis(), warm.as_millis(),
        warm.as_millis() as i64 - cold.as_millis() as i64
    );
}

#[test]
fn baseline_small() {
    if !tools_available() {
        eprintln!("SKIP: latex/dvisvgm not on PATH");
        return;
    }
    let preamble = "\\documentclass{article}\n\\usepackage{amsmath,amssymb}\n";
    let src = "$a+b$ and $x^2 + y^2 = z^2$ and $\\alpha$";
    let frags = vec![(0, 5), (10, 27), (32, 40)];
    bench("small/3 frags", preamble, src, frags);
}

#[test]
fn baseline_medium_heavy_preamble() {
    if !tools_available() {
        eprintln!("SKIP");
        return;
    }
    let preamble = "\
\\documentclass{article}
\\usepackage{amsmath,amssymb,amsthm,mathtools}
\\usepackage{bm}
\\newcommand{\\R}{\\mathbb{R}}
\\newcommand{\\N}{\\mathbb{N}}
\\newcommand{\\E}{\\mathbb{E}}
\\DeclareMathOperator*{\\argmax}{arg\\,max}
\\DeclareMathOperator*{\\argmin}{arg\\,min}
";
    // 8 fragments similar to training.tex
    let src = "$\\beta_1=0.9$ $\\beta_2=0.98$ $\\epsilon=10^{-9}$ $\\R$ $\\argmax_x f(x)$ $\\E[X]$ $x^n$ $a+b$";
    let frags = vec![
        (0, 13), (14, 28), (29, 46), (47, 52),
        (53, 69), (70, 77), (78, 83), (84, 89),
    ];
    bench("med/8 frags heavy", preamble, src, frags);
}

#[test]
fn baseline_warm_vs_cold() {
    if !tools_available() {
        eprintln!("SKIP");
        return;
    }
    let preamble = "\\documentclass{article}\n\\usepackage{amsmath}\n";
    let src = "$a+b$ $c-d$ $x^2$ $y_n$ $\\pi$ $\\sum_i$";
    let frags = vec![(0,5),(6,11),(12,17),(18,23),(24,29),(30,37)];
    bench_warm("warm/6 frags", preamble, src, frags);
}
