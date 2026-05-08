export type StrengthLevel = 'empty' | 'weak' | 'fair' | 'good' | 'strong';

export type StrengthResult = {
	level: StrengthLevel;
	score: number;
	failedRules: string[];
	passed: boolean;
};

export type PasswordRuleResult = {
	label: string;
	passed: boolean;
};

const COMMON_PASSWORDS = new Set([
	'password',
	'123456',
	'qwerty',
	'letmein',
	'welcome',
	'monkey',
	'dragon',
	'master',
	'sunshine',
	'princess',
	'abc123',
	'iloveyou',
	'admin',
	'login',
	'hello',
	'shadow',
	'superman',
	'michael',
	'football',
	'baseball',
]);

const SPECIAL_CHARACTERS = "!@#$%^&*()_+-=[]{}|;':,./<>?";

export function passwordRuleResults(password: string): PasswordRuleResult[] {
	return [
		{ label: '8+ characters', passed: password.length >= 8 },
		{ label: 'Uppercase letter', passed: /[A-Z]/.test(password) },
		{ label: 'Lowercase letter', passed: /[a-z]/.test(password) },
		{ label: 'Add a number', passed: /\d/.test(password) },
		{ label: 'Special character required', passed: Array.from(password).some((character) => SPECIAL_CHARACTERS.includes(character)) },
		{ label: 'Avoid common passwords', passed: !COMMON_PASSWORDS.has(password.trim().toLowerCase()) },
	];
}

function scoreToLevel(score: number): StrengthLevel {
	if (score <= 1) {
		return 'weak';
	}
	if (score === 2) {
		return 'fair';
	}
	if (score === 3) {
		return 'good';
	}
	return 'strong';
}

export function checkPasswordStrength(password: string): StrengthResult {
	if (password.length === 0) {
		return {
			level: 'empty',
			score: 0,
			failedRules: passwordRuleResults(password).map((rule) => rule.label),
			passed: false,
		};
	}

	const rules = passwordRuleResults(password);
	const failedRules = rules.filter((rule) => !rule.passed).map((rule) => rule.label);
	const passedRules = rules.length - failedRules.length;
	const score = Math.min(4, Math.max(1, passedRules - 2));
	const level = scoreToLevel(score);
	return {
		level,
		score,
		failedRules,
		passed: level === 'good' || level === 'strong',
	};
}
