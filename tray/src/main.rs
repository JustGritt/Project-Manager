//! pm-tray: a menu bar / system tray light for the pm board.
//!
//! Polls the board's `/api/status` every few seconds and shows a filled green
//! dot while it is running, a hollow grey ring when it isn't. All actions
//! (start, stop, autostart) shell out to the `pm` script, so the logic lives
//! in one place. Launched by `pm tray on`, which passes the paths it needs.

#![cfg_attr(windows, windows_subsystem = "windows")]

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::process::Command;
use std::thread;
use std::time::Duration;

use serde::Deserialize;
use tao::event::{Event, StartCause};
use tao::event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy};
use tray_icon::menu::{CheckMenuItem, Menu, MenuEvent, MenuId, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};

const POLL: Duration = Duration::from_secs(5);
const GREEN: [u8; 3] = [46, 160, 67];
const GREY: [u8; 3] = [142, 142, 142];

#[derive(Deserialize, Clone, PartialEq, Default)]
struct Focus {
    name: String,
    #[serde(default)]
    next: String,
}

#[derive(Deserialize, Clone, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
struct Status {
    focus: Vec<Focus>,
    focus_limit: u32,
    ideas_ready: u32,
    autostart: bool,
}

enum UserEvent {
    Status(Option<Status>),
    Autostart(bool),
    Menu(MenuEvent),
}

#[derive(Clone)]
struct Config {
    python: String,
    script: String,
    port: u16,
    pidfile: Option<String>,
}

impl Config {
    fn from_args() -> Config {
        let mut cfg = Config { python: "python3".into(), script: "pm".into(), port: 4242, pidfile: None };
        let mut args = std::env::args().skip(1);
        while let Some(flag) = args.next() {
            let value = args.next().unwrap_or_default();
            match flag.as_str() {
                "--python" => cfg.python = value,
                "--script" => cfg.script = value,
                "--port" => cfg.port = value.parse().unwrap_or(4242),
                "--pidfile" => cfg.pidfile = Some(value),
                _ => {}
            }
        }
        cfg
    }

    fn url(&self) -> String {
        format!("http://localhost:{}", self.port)
    }
}

/// GET /api/status over a plain socket: localhost only, so no HTTP client crate needed.
fn fetch_status(port: u16) -> Option<Status> {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(500)).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(3))).ok()?;
    write!(stream, "GET /api/status HTTP/1.0\r\nHost: localhost:{port}\r\nConnection: close\r\n\r\n").ok()?;
    let mut response = String::new();
    stream.read_to_string(&mut response).ok()?;
    let (head, body) = response.split_once("\r\n\r\n")?;
    if !head.lines().next()?.contains(" 200 ") {
        return None;
    }
    serde_json::from_str(body).ok()
}

fn hidden(cmd: &mut Command) -> &mut Command {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    cmd
}

fn run_pm(cfg: &Config, args: &[&str]) -> String {
    hidden(Command::new(&cfg.python).arg(&cfg.script).args(args))
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

fn autostart_enabled(cfg: &Config) -> bool {
    run_pm(cfg, &["autostart", "status"]).lines().next().is_some_and(|l| l.contains(": on"))
}

fn open_url(url: &str) {
    let mut cmd = if cfg!(target_os = "macos") {
        Command::new("open")
    } else if cfg!(windows) {
        let mut c = Command::new("cmd");
        c.args(["/C", "start", ""]);
        c
    } else {
        Command::new("xdg-open")
    };
    let _ = hidden(cmd.arg(url)).spawn();
}

/// A dot drawn in code: filled when running, a ring when not, so the state
/// reads by shape as well as colour.
fn dot(filled: bool) -> Icon {
    const SIZE: u32 = 36;
    let (center, radius, ring) = (SIZE as f32 / 2.0, 7.5, 2.2);
    let color = if filled { GREEN } else { GREY };
    let mut rgba = Vec::with_capacity((SIZE * SIZE * 4) as usize);
    for y in 0..SIZE {
        for x in 0..SIZE {
            let d = ((x as f32 + 0.5 - center).powi(2) + (y as f32 + 0.5 - center).powi(2)).sqrt();
            let outer = (radius + 0.5 - d).clamp(0.0, 1.0);
            let inner = if filled { 0.0 } else { (radius - ring + 0.5 - d).clamp(0.0, 1.0) };
            rgba.extend_from_slice(&color);
            rgba.push(((outer - inner) * 255.0) as u8);
        }
    }
    Icon::from_rgba(rgba, SIZE, SIZE).expect("valid icon")
}

fn truncate(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        text.to_string()
    } else {
        text.chars().take(max - 1).collect::<String>() + "…"
    }
}

/// Menu ids we react to; everything else is a label.
#[derive(Default)]
struct Ids {
    open: Vec<MenuId>,
    toggle: Option<MenuId>,
    login: Option<MenuId>,
    quit: Option<MenuId>,
}

fn build_menu(cfg: &Config, status: &Option<Status>, autostart: bool) -> (Menu, Ids) {
    let menu = Menu::new();
    let mut ids = Ids::default();
    let label = |text: &str| MenuItem::new(text, false, None);
    let sep = PredefinedMenuItem::separator;

    match status {
        Some(s) => {
            let _ = menu.append(&label(&format!("Board running at localhost:{}", cfg.port)));
            let _ = menu.append(&sep());
            let _ = menu.append(&label(&format!("This week's focus ({}/{})", s.focus.len(), s.focus_limit)));
            if s.focus.is_empty() {
                let _ = menu.append(&label("   Nothing in focus yet"));
            }
            for f in &s.focus {
                let text = if f.next.is_empty() {
                    format!("★ {}", f.name)
                } else {
                    format!("★ {}  →  {}", f.name, truncate(&f.next, 48))
                };
                let item = MenuItem::new(text, true, None);
                ids.open.push(item.id().clone());
                let _ = menu.append(&item);
            }
            if s.ideas_ready > 0 {
                let plural = if s.ideas_ready == 1 { "idea is" } else { "ideas are" };
                let item = MenuItem::new(format!("💡 {} {plural} ready to start", s.ideas_ready), true, None);
                ids.open.push(item.id().clone());
                let _ = menu.append(&item);
            }
        }
        None => {
            let _ = menu.append(&label("Board not running"));
        }
    }

    let _ = menu.append(&sep());
    let open = MenuItem::new("Open board", true, None);
    let toggle = MenuItem::new(if status.is_some() { "Stop board" } else { "Start board" }, true, None);
    let login = CheckMenuItem::new("Start board at login", true, autostart, None);
    let quit = MenuItem::new("Quit pm menu", true, None);
    ids.open.push(open.id().clone());
    ids.toggle = Some(toggle.id().clone());
    ids.login = Some(login.id().clone());
    ids.quit = Some(quit.id().clone());
    let _ = menu.append_items(&[&open, &toggle, &login, &sep(), &quit]);
    (menu, ids)
}

/// Run a pm command off the UI thread, then refresh the status.
fn in_background(cfg: &Config, proxy: &EventLoopProxy<UserEvent>, job: impl FnOnce(&Config) + Send + 'static) {
    let (cfg, proxy) = (cfg.clone(), proxy.clone());
    thread::spawn(move || {
        job(&cfg);
        let _ = proxy.send_event(UserEvent::Status(fetch_status(cfg.port)));
    });
}

fn main() {
    let cfg = Config::from_args();
    if let Some(path) = &cfg.pidfile {
        let _ = std::fs::write(path, std::process::id().to_string());
    }

    #[allow(unused_mut)]
    let mut event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    #[cfg(target_os = "macos")]
    {
        use tao::platform::macos::{ActivationPolicy, EventLoopExtMacOS};
        event_loop.set_activation_policy(ActivationPolicy::Accessory); // no Dock icon
    }

    let proxy = event_loop.create_proxy();
    let menu_proxy = proxy.clone();
    MenuEvent::set_event_handler(Some(move |e| {
        let _ = menu_proxy.send_event(UserEvent::Menu(e));
    }));

    // Poll the board in the background.
    let poll_proxy = proxy.clone();
    let port = cfg.port;
    thread::spawn(move || loop {
        if poll_proxy.send_event(UserEvent::Status(fetch_status(port))).is_err() {
            break;
        }
        thread::sleep(POLL);
    });
    // The board reports autostart while it runs; ask pm directly once at launch.
    let auto_proxy = proxy.clone();
    let auto_cfg = cfg.clone();
    thread::spawn(move || {
        let _ = auto_proxy.send_event(UserEvent::Autostart(autostart_enabled(&auto_cfg)));
    });

    let mut tray: Option<TrayIcon> = None;
    let mut status: Option<Status> = None;
    let mut autostart = false;
    let mut ids = Ids::default();
    let mut first = true;

    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;
        let mut refresh = false;

        match event {
            // macOS needs the tray created once the event loop is running.
            Event::NewEvents(StartCause::Init) => {
                let (menu, new_ids) = build_menu(&cfg, &status, autostart);
                ids = new_ids;
                tray = TrayIconBuilder::new()
                    .with_menu(Box::new(menu))
                    .with_icon(dot(false))
                    .with_title("pm")
                    .with_tooltip("pm: checking…")
                    .build()
                    .ok();
            }
            Event::UserEvent(UserEvent::Status(new)) => {
                if let Some(s) = &new {
                    autostart = s.autostart;
                }
                refresh = first || new != status;
                first = false;
                status = new;
            }
            Event::UserEvent(UserEvent::Autostart(on)) => {
                refresh = on != autostart;
                autostart = on;
            }
            Event::UserEvent(UserEvent::Menu(e)) => {
                let id = &e.id;
                if ids.quit.as_ref() == Some(id) {
                    if let Some(path) = &cfg.pidfile {
                        let _ = std::fs::remove_file(path);
                    }
                    tray.take();
                    *control_flow = ControlFlow::Exit;
                } else if ids.toggle.as_ref() == Some(id) {
                    let running = status.is_some();
                    in_background(&cfg, &proxy, move |c| {
                        run_pm(c, &[if running { "stop" } else { "start" }]);
                    });
                } else if ids.login.as_ref() == Some(id) {
                    let (target, auto_proxy) = (!autostart, proxy.clone());
                    in_background(&cfg, &proxy, move |c| {
                        run_pm(c, &["autostart", if target { "on" } else { "off" }]);
                        let _ = auto_proxy.send_event(UserEvent::Autostart(autostart_enabled(c)));
                    });
                } else if ids.open.contains(id) {
                    let running = status.is_some();
                    in_background(&cfg, &proxy, move |c| {
                        if !running {
                            run_pm(c, &["start"]);
                        }
                        open_url(&c.url());
                    });
                }
            }
            _ => {}
        }

        if refresh {
            if let Some(tray) = &tray {
                let running = status.is_some();
                let _ = tray.set_icon(Some(dot(running)));
                let _ = tray.set_tooltip(Some(if running { "pm: board running" } else { "pm: board not running" }));
                let (menu, new_ids) = build_menu(&cfg, &status, autostart);
                ids = new_ids;
                tray.set_menu(Some(Box::new(menu)));
            }
        }
    });
}
