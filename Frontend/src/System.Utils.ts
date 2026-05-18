import { mergeClasses } from '@fluentui/react-components';

export const cn = (...args: (string | undefined | null | false)[]): string =>
  mergeClasses(...(args.filter(Boolean) as string[]));
