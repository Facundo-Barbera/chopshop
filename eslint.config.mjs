import js from "@eslint/js";
import globals from "globals";

const noComments = {
  meta: { type: "suggestion", messages: { comment: "Comentarios prohibidos: el código debe explicarse solo." }, schema: [] },
  create(context) {
    return {
      Program() {
        for (const c of context.sourceCode.getAllComments()) {
          if (/^\s*eslint-/.test(c.value)) continue;
          context.report({ loc: c.loc, messageId: "comment" });
        }
      },
    };
  },
};

export default [
  { ignores: ["**/node_modules/**", "apps/mac/Resources/web/**", "**/dist/**"] },
  js.configs.recommended,
  {
    files: ["**/*.{js,jsx,mjs}"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      parserOptions: { ecmaFeatures: { jsx: true } },
      globals: { ...globals.browser, ...globals.node },
    },
    plugins: { local: { rules: { "no-comments": noComments } } },
    rules: { "local/no-comments": "error" },
  },
];
