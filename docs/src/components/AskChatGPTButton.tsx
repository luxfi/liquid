import React from "react";
import { useLocation } from "@docusaurus/router";
import useIsBrowser from "@docusaurus/useIsBrowser";

export default function AskChatGPTButton() {
  const isBrowser = useIsBrowser();
  const { pathname, search, hash } = useLocation();

  if (!isBrowser) return null;

  const pageUrl = window.location.href;

  const prompt =
    `Please research and analyze this page: ${pageUrl} ` +
    `so I can ask you questions about it. Once you have read it, ` +
    `prompt me for my questions. Do not post content from the page ` +
    `in your response. Any of my follow-up questions must reference ` +
    `the site I gave you.`;

  const chatUrl =
    "https://chat.openai.com/?model=gpt-4o&q=" + encodeURIComponent(prompt);

  return (
    <a
      href={chatUrl}
      target="_blank"
      rel="noopener noreferrer"
      className="button button--primary"
    >
      Ask&nbsp;in&nbsp;ChatGPT
    </a>
  );
}
