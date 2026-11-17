// bdd-gates' own gplint rule: every Scenario and Scenario Outline says what should be true afterwards.
// A scenario with no Then step checks nothing, so it cannot go red for the right reason. A Then from the
// feature's Background does not count: an outcome belongs to the scenario that causes it.
export const name = 'scenario-has-then';

export function run({ feature }) {
  if (!feature) return [];
  const errors = [];
  const check = (children) => children.forEach((child) => {
    if (child.rule) check(child.rule.children);
    const scenario = child.scenario;
    if (!scenario) return;
    let effective = null;
    const hasThen = scenario.steps.some((step) => {
      // And and But take the meaning of the step before them.
      if (step.keywordType !== 'Conjunction') effective = step.keywordType;
      return effective === 'Outcome';
    });
    if (!hasThen) {
      errors.push({
        message: `Scenario "${scenario.name}" has no Then step: say what should be true afterwards.`,
        rule: name,
        line: scenario.location.line,
        column: scenario.location.column,
      });
    }
  });
  check(feature.children);
  return errors;
}

export const documentation = {
  description: 'Every Scenario and Scenario Outline has at least one Then step.',
  examples: [{ title: 'Example', description: 'Enable rule', config: { [name]: 'error' } }],
};
