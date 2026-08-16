"use client";

import { useEffect, useRef } from "react";
import { lightLogin } from "@/lib/light-auth";

const DEV_EMAIL = "dev@agentsmesh.local";
const DEV_PASSWORD = "devpass123";

function isLocalHost(): boolean {
  if (typeof window === "undefined") return false;
  return ["localhost", "127.0.0.1", "::1"].includes(window.location.hostname);
}

function isDevAutoLoginEnabled(): boolean {
  if (process.env.NEXT_PUBLIC_DEV_AUTO_LOGIN === "false") return false;
  if (process.env.NEXT_PUBLIC_DEV_AUTO_LOGIN === "true") return true;
  return process.env.NODE_ENV === "development" || process.env.NEXT_PUBLIC_E2E === "true";
}

export function useDevAutoLogin(opts: {
  disabled: boolean;
  navigateAfterLogin: () => Promise<void>;
  setLoading: (loading: boolean) => void;
  setError: (message: string) => void;
  errorMessage: string;
}) {
  const attemptedRef = useRef(false);

  useEffect(() => {
    if (attemptedRef.current) return;
    if (!isDevAutoLoginEnabled() || !isLocalHost()) return;
    if (opts.disabled) return;

    attemptedRef.current = true;
    opts.setLoading(true);
    opts.setError("");

    lightLogin({ email: DEV_EMAIL, password: DEV_PASSWORD })
      .then(opts.navigateAfterLogin)
      .catch(() => opts.setError(opts.errorMessage))
      .finally(() => opts.setLoading(false));
  }, [opts]);
}
