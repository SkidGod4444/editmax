"use client";

import dynamic from "next/dynamic";

// Below-the-fold client parts, each in its own chunk: still prerendered into the page's HTML, but their JavaScript is
// fetched after the hero's. (next/dynamic only splits when called from a client module like this one.)
export const Looks = dynamic(() => import("./looks").then((m) => m.Looks));
export const AgentsDiagram = dynamic(() => import("./agents-diagram").then((m) => m.AgentsDiagram));
export const ConnectTabs = dynamic(() => import("./connect-tabs").then((m) => m.ConnectTabs));
