import { useEffect, useRef, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import {
  isPermissionGranted,
  requestPermission,
} from "@tauri-apps/plugin-notification";
import {
  ArrowRight,
  Bell,
  Bot,
  Check,
  Database,
  Download,
  ShieldCheck,
} from "lucide-react";
import { api, OllamaStatus } from "./api";

export function Onboarding({
  status,
  onRefresh,
  onComplete,
  onMessage,
}: {
  status: OllamaStatus | null;
  onRefresh: () => Promise<void>;
  onComplete: () => void;
  onMessage: (message: string) => void;
}) {
  const [step, setStep] = useState(0);
  const [permission, setPermission] = useState<
    "unknown" | "granted" | "denied"
  >("unknown");
  const [downloading, setDownloading] = useState(false);
  const dialogRef = useRef<HTMLElement>(null);
  useEffect(() => {
    dialogRef.current?.focus();
    void isPermissionGranted().then((value) =>
      setPermission(value ? "granted" : "unknown"),
    );
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Tab" || !dialogRef.current) return;
      const items = dialogRef.current.querySelectorAll<HTMLElement>(
        'button:not(:disabled), [tabindex="0"]',
      );
      if (!items.length) return;
      const first = items[0];
      const last = items[items.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, []);
  const ready = status?.running && status.modelInstalled;
  const finish = () => {
    localStorage.setItem("dayplan-onboarding", "complete");
    onComplete();
  };
  async function enableNotifications() {
    try {
      const next = await requestPermission();
      setPermission(next === "granted" ? "granted" : "denied");
    } catch (cause) {
      onMessage(cause instanceof Error ? cause.message : String(cause));
    }
  }
  async function downloadModel() {
    if (
      !window.confirm(
        "Download qwen3:8b now? It is about 5.2 GB and DayPlan recommends roughly 10 GB of free space. The model's license will be stored with the model metadata.",
      )
    )
      return;
    setDownloading(true);
    const poll = window.setInterval(() => void onRefresh(), 750);
    try {
      await api.downloadModel();
      await onRefresh();
    } catch (cause) {
      onMessage(cause instanceof Error ? cause.message : String(cause));
    } finally {
      window.clearInterval(poll);
      setDownloading(false);
    }
  }
  const panels = [
    <div className="onboarding-panel" key="storage">
      <span className="onboarding-icon">
        <Database size={26} />
      </span>
      <p>STEP 1 OF 3</p>
      <h2>Your day stays on this device.</h2>
      <div className="onboarding-copy">
        <ShieldCheck size={18} />
        <span>
          Events and tasks live in a local SQLite database. There are no
          accounts, sync servers, or cloud AI fallbacks.
        </span>
      </div>
      <button className="onboarding-next" onClick={() => setStep(1)}>
        Continue <ArrowRight size={16} />
      </button>
    </div>,
    <div className="onboarding-panel" key="model">
      <span className="onboarding-icon">
        <Bot size={26} />
      </span>
      <p>STEP 2 OF 3</p>
      <h2>Your private AI runs inside DayPlan.</h2>
      <div className={`setup-status ${ready ? "ready" : ""}`}>
        <span />
        {status?.detail ?? "Checking Ollama and qwen3:8b…"}
      </div>
      <p className="onboarding-model-note">
        The Ollama runtime is included. The qwen3:8b model is a separate
        one-time download of about 5.2 GB; allow roughly 10 GB of free space.
      </p>
      {status?.download?.percent !== null && status?.download && (
        <progress max="100" value={status.download.percent ?? undefined}>
          {status.download.percent ?? 0}%
        </progress>
      )}
      <div className="onboarding-links">
        {!ready && (
          <button disabled={downloading} onClick={() => void downloadModel()}>
            <Download size={15} />{" "}
            {downloading ? "Downloading…" : "Download model"}
          </button>
        )}
        {downloading && (
          <button onClick={() => void api.cancelModelDownload()}>Cancel</button>
        )}
        <button
          onClick={() => void openUrl("https://ollama.com/library/qwen3:8b")}
        >
          Model details &amp; license
        </button>
        <button onClick={() => void onRefresh()}>Check again</button>
      </div>
      <button className="onboarding-next" onClick={() => setStep(2)}>
        {ready ? "Model ready" : "Set up later"} <ArrowRight size={16} />
      </button>
    </div>,
    <div className="onboarding-panel" key="notifications">
      <span className="onboarding-icon">
        <Bell size={26} />
      </span>
      <p>STEP 3 OF 3</p>
      <h2>Reminders are optional.</h2>
      <div className="onboarding-copy">
        <Bell size={18} />
        <span>
          DayPlan asks for OS permission only when you enable a reminder. The
          app must remain running in the tray to deliver one.
        </span>
      </div>
      {permission === "granted" ? (
        <div className="permission-ready">
          <Check size={16} /> Notifications allowed
        </div>
      ) : (
        <button
          className="permission-button"
          onClick={() => void enableNotifications()}
        >
          Allow notifications
        </button>
      )}
      <button className="onboarding-next" onClick={finish}>
        Open DayPlan <ArrowRight size={16} />
      </button>
    </div>,
  ];
  return (
    <div className="onboarding-backdrop">
      <section
        ref={dialogRef}
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
        aria-label="Welcome to DayPlan"
        className="onboarding-card"
      >
        <div className="onboarding-brand">
          <span>D</span> DayPlan
        </div>
        {panels[step]}
        <div className="onboarding-dots" aria-label={`Step ${step + 1} of 3`}>
          {[0, 1, 2].map((index) => (
            <i key={index} className={index === step ? "active" : ""} />
          ))}
        </div>
      </section>
    </div>
  );
}
