import React from "react";
import DocBreadcrumbs from "@theme-original/DocBreadcrumbs";
import AskChatGPTButton from "../../components/AskChatGPTButton";
import styles from "./styles.module.css"; // we’ll create this next

export default function DocBreadcrumbsWrapper(props) {
  return (
    <div className={styles.row}>
      <DocBreadcrumbs {...props} />
      <AskChatGPTButton />
    </div>
  );
}
