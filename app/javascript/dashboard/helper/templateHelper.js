// Constants
export const DEFAULT_LANGUAGE = 'en';
export const DEFAULT_CATEGORY = 'UTILITY';
export const COMPONENT_TYPES = {
  HEADER: 'HEADER',
  BODY: 'BODY',
  FOOTER: 'FOOTER',
  BUTTONS: 'BUTTONS',
};
export const MEDIA_FORMATS = ['IMAGE', 'VIDEO', 'DOCUMENT'];

// Presentational grouping for the template picker, derived from the template name.
// Extend the keyword lists here as new template naming conventions appear.
export const TEMPLATE_GROUPS = {
  ALL: 'ALL',
  GREETINGS: 'GREETINGS',
  FOLLOW_UPS: 'FOLLOW_UPS',
  QUOTES_AND_DETAILS: 'QUOTES_AND_DETAILS',
  OTHER: 'OTHER',
};

export const TEMPLATE_GROUP_KEYWORDS = {
  [TEMPLATE_GROUPS.GREETINGS]: [
    'greeting',
    'welcome',
    'intro',
    'checkin',
    'check_in',
  ],
  [TEMPLATE_GROUPS.FOLLOW_UPS]: [
    'followup',
    'follow_up',
    'reminder',
    'missed',
    'no_answer',
    'reengage',
  ],
  [TEMPLATE_GROUPS.QUOTES_AND_DETAILS]: [
    'quote',
    'detail',
    'artwork',
    'sample',
    'doc',
    'payment',
    'call',
  ],
};

export const getTemplateGroup = template => {
  const name = template.name?.toLowerCase() ?? '';
  const match = Object.entries(TEMPLATE_GROUP_KEYWORDS).find(([, keywords]) =>
    keywords.some(keyword => name.includes(keyword))
  );

  return match ? match[0] : TEMPLATE_GROUPS.OTHER;
};

export const findComponentByType = (template, type) =>
  template.components?.find(component => component.type === type);

export const processVariable = str => {
  return str.replace(/{{|}}/g, '');
};

export const allKeysRequired = value => {
  const keys = Object.keys(value);
  return keys.every(key => value[key]);
};

export const replaceTemplateVariables = (templateText, processedParams) => {
  return templateText.replace(/{{([^}]+)}}/g, (match, variable) => {
    const variableKey = processVariable(variable);
    return processedParams.body?.[variableKey] || `{{${variable}}}`;
  });
};

export const buildTemplateParameters = (template, hasMediaHeaderValue) => {
  const allVariables = {};

  const bodyComponent = findComponentByType(template, COMPONENT_TYPES.BODY);
  const headerComponent = findComponentByType(template, COMPONENT_TYPES.HEADER);

  if (!bodyComponent) return allVariables;

  const templateString = bodyComponent.text;

  // Process body variables
  const matchedVariables = templateString.match(/{{([^}]+)}}/g);
  if (matchedVariables) {
    allVariables.body = {};
    matchedVariables.forEach(variable => {
      const key = processVariable(variable);
      allVariables.body[key] = '';
    });
  }

  if (hasMediaHeaderValue) {
    if (!allVariables.header) allVariables.header = {};
    allVariables.header.media_url = '';
    allVariables.header.media_type = headerComponent.format.toLowerCase();

    // For document templates, include media_name field for filename support
    if (headerComponent.format.toLowerCase() === 'document') {
      allVariables.header.media_name = '';
    }
  }

  // Process button variables
  const buttonComponents = template.components.filter(
    component => component.type === COMPONENT_TYPES.BUTTONS
  );

  buttonComponents.forEach(buttonComponent => {
    if (buttonComponent.buttons) {
      buttonComponent.buttons.forEach((button, index) => {
        // Handle URL buttons with variables
        if (button.type === 'URL' && button.url && button.url.includes('{{')) {
          const buttonVars = button.url.match(/{{([^}]+)}}/g) || [];
          if (buttonVars.length > 0) {
            if (!allVariables.buttons) allVariables.buttons = [];
            allVariables.buttons[index] = {
              type: 'url',
              parameter: '',
              url: button.url,
              variables: buttonVars.map(v => processVariable(v)),
            };
          }
        }

        // Handle copy code buttons
        if (button.type === 'COPY_CODE') {
          if (!allVariables.buttons) allVariables.buttons = [];
          allVariables.buttons[index] = {
            type: 'copy_code',
            parameter: '',
          };
        }
      });
    }
  });

  return allVariables;
};
