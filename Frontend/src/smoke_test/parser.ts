export type ParsedINI = {
  [section: string]: {
    [key: string]: string;
  };
};

export function parseAlgebraicINI(iniString: string): ParsedINI {
  const lines = iniString.split('\n');
  const result: ParsedINI = {};
  let currentSection = '';
  const variables: Record<string, string> = {};

  for (let line of lines) {
    line = line.split(';')[0].trim(); // ignore comments
    if (!line) continue;

    if (line.startsWith('[') && line.endsWith(']')) {
      currentSection = line.substring(1, line.length - 1);
      result[currentSection] = {};
    } else if (line.includes('=')) {
      const parts = line.split('=');
      const key = parts[0].trim();
      let value = parts.slice(1).join('=').trim();

      // Resolve variables
      value = value.replace(/\$([a-zA-Z0-9_]+)/g, (match, varName) => {
        return variables[varName] !== undefined ? variables[varName] : match;
      });

      if (key.startsWith('$')) {
        // Variable declaration
        variables[key.substring(1)] = value;
      } else {
        if (currentSection) {
          result[currentSection][key] = value;
        }
      }
    }
  }

  return result;
}
