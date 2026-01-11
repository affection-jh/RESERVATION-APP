/**
 * 간결한 로깅 유틸리티
 * 
 * 아이콘 + 핵심 내용 + 요청 데이터 형식으로 로그 출력
 */

interface LogData {
    [key: string]: any;
}

const ICONS = {
    info: 'ℹ️',
    warn: '⚠️',
    error: '❌',
    success: '✅',
} as const;

function formatData(data?: LogData): string {
    if (!data || Object.keys(data).length === 0) return '';

    // 민감한 정보 마스킹
    const sanitized: LogData = {};
    for (const [key, value] of Object.entries(data)) {
        if (typeof value === 'string' && (key.toLowerCase().includes('pin') || key.toLowerCase().includes('password'))) {
            sanitized[key] = '***';
        } else if (typeof value === 'object' && value !== null) {
            sanitized[key] = JSON.stringify(value).substring(0, 100); // 최대 100자
        } else {
            sanitized[key] = String(value).substring(0, 50); // 최대 50자
        }
    }
    return ` | ${JSON.stringify(sanitized)}`;
}

export function logInfo(message: string, data?: LogData): void {
    console.log(`${ICONS.info} ${message}${formatData(data)}`);
}

export function logWarn(message: string, data?: LogData): void {
    console.warn(`${ICONS.warn} ${message}${formatData(data)}`);
}

export function logError(message: string, error?: Error | unknown, data?: LogData): void {
    const errorMsg = error instanceof Error ? error.message : String(error);
    console.error(`${ICONS.error} ${message} | Error: ${errorMsg}${formatData(data)}`);
}

export function logSuccess(message: string, data?: LogData): void {
    console.log(`${ICONS.success} ${message}${formatData(data)}`);
}

/**
 * 함수 호출 시작 로그
 */
export function logFunctionStart(functionName: string, data?: LogData): void {
    logInfo(`[${functionName}] 시작`, data);
}

/**
 * 함수 호출 성공 로그
 */
export function logFunctionSuccess(functionName: string, data?: LogData): void {
    logSuccess(`[${functionName}] 완료`, data);
}

/**
 * 함수 호출 실패 로그
 */
export function logFunctionError(functionName: string, error: Error | unknown, data?: LogData): void {
    logError(`[${functionName}] 실패`, error, data);
}
