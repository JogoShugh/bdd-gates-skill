// Every rule is an error, so `npx eslint .` exits non-zero on any violation.
// Rules with no options use their own default limits. Do not add numbers.
import sonarjs from "eslint-plugin-sonarjs";
import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["**/dist/**", "**/node_modules/**", "**/*.d.ts", "**/generated/**", "**/*.generated.ts"] },
  {
    files: ["**/src/**/*.ts", "src/**/*.ts"],
    ignores: ["**/*.test.ts", "**/*.spec.ts"],
    languageOptions: { parser: tseslint.parser },
    // An eslint-disable comment must not be a way past the gate.
    linterOptions: { noInlineConfig: true },
    plugins: { "@typescript-eslint": tseslint.plugin, sonarjs },
    rules: {
      complexity: "error",
      "max-depth": "error",
      "max-params": "error",
      "max-statements": "error",
      "max-lines-per-function": "error",
      "max-nested-callbacks": "error",
      "no-nested-ternary": "error",
      "sonarjs/cognitive-complexity": "error",
      "sonarjs/no-duplicate-string": "error",
      // Policy, not a threshold: no casts, so raw JSON is parsed into types at the boundary.
      "@typescript-eslint/consistent-type-assertions": ["error", { assertionStyle: "never" }],
      "@typescript-eslint/no-explicit-any": "error",
    },
  },
);
