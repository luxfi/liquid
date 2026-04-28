import React from "react";
import Chat from "@site/src/components/Chat";

export default function Root({ children }: { children: React.ReactNode }) {
  return (
    <>
      {children}
      <Chat />
    </>
  );
}
