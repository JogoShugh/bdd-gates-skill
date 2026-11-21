// bdd-gates' own gplint rule: two scenarios whose steps are the same but for their values are one Scenario
// Outline. A step's shape is its meaning (Given, When or Then, And and But taking the step before) and its
// text with each value replaced: a quoted string, a number, an outline <parameter>; a data table counts by its
// columns, a doc string by its whole content. Only exact shapes are reported, so a scenario
// that differs in a single word is left to the author.
export const name = 'no-same-shape-scenarios';

const shapeOf = (steps) => {
  let effective = 'Context';
  return steps.map((step) => {
    if (step.keywordType !== 'Conjunction') effective = step.keywordType;
    const text = step.text
      .replace(/"[^"]*"|'[^']*'/g, '<text>')
      .replace(/<[^>]+>/g, '<value>')
      .replace(/-?\b\d+(?:\.\d+)?\b/g, '<number>')
      .replace(/\s+/g, ' ')
      .trim();
    const table = step.dataTable ? ` [table of ${step.dataTable.rows[0]?.cells.length ?? 0}]` : '';
    // A doc string is a whole document (a request, an answer, a script): its content is the scenario's
    // substance, not a value an Examples table could carry.
    const doc = step.docString ? ` [doc string]\n${step.docString.content}` : '';
    return `${effective}: ${text}${table}${doc}`;
  }).join('\n');
};

export function run({ feature }) {
  if (!feature) return [];
  const errors = [];
  const check = (children) => {
    const seen = new Map();
    children.forEach((child) => {
      if (child.rule) check(child.rule.children);
      const scenario = child.scenario;
      if (!scenario || scenario.steps.length === 0) return;
      const shape = shapeOf(scenario.steps);
      const first = seen.get(shape);
      if (first) {
        errors.push({
          message: `Scenario "${scenario.name}" has the same steps as "${first.name}" (line ${first.location.line}) `
            + 'with different values: make them one Scenario Outline with Examples.',
          rule: name,
          line: scenario.location.line,
          column: scenario.location.column,
        });
      } else {
        seen.set(shape, scenario);
      }
    });
  };
  check(feature.children);
  return errors;
}

export const documentation = {
  description: 'Disallows scenarios whose steps differ only in their values: they are one Scenario Outline.',
  examples: [{ title: 'Example', description: 'Enable rule', config: { [name]: 'error' } }],
};
