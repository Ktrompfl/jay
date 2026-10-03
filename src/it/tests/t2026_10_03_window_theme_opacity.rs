use crate::it::test_client::TestClientExt;
use crate::it::test_error::TestResult;
use crate::it::testrun::TestRun;
use jay_config::_private::WindowThemeKind;
use std::rc::Rc;

testcase!();

/// Test the window opacity.
async fn test(run: Rc<TestRun>) -> TestResult {
    let ds = run.create_default_setup().await?;
    const W: WindowThemeKind = WindowThemeKind::ParentTheme;

    let client = run.create_client()?;
    let win = client.create_window().await?;
    win.set_color(255, 255, 255, 255);
    win.map2().await?;
    client.sync().await;
    let window = run.cfg.get_keyboard_window(ds.seat.id())?;

    let opaque = client.screenshot_qoi(false).await?;

    run.cfg.set_window_theme_opacity(window, W, Some(0.5))?;
    client.sync().await;
    tassert_eq!(run.cfg.get_window_theme_opacity(window, W)?, Some(0.5));
    let translucent = client.screenshot_qoi(false).await?;
    tassert!(opaque != translucent);

    // Out-of-range values are rejected.
    run.cfg.set_window_theme_opacity(window, W, Some(1.5))?;
    client.sync().await;
    tassert_eq!(run.cfg.get_window_theme_opacity(window, W)?, Some(0.5));

    run.cfg.set_window_theme_opacity(window, W, Some(1.0))?;
    client.sync().await;
    tassert!(client.screenshot_qoi(false).await? == opaque);

    run.cfg.set_window_theme_opacity(window, W, None)?;
    client.sync().await;
    tassert_eq!(run.cfg.get_window_theme_opacity(window, W)?, None);
    tassert!(client.screenshot_qoi(false).await? == opaque);

    Ok(())
}
