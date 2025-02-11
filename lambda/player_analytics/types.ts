export interface PlayerSession {
    playerId: string;
    timestamp: number;
    sessionId: string;
    playerName: string;
    loginTime: number;
    logoutTime: number;
    duration: number;
    ttl: number;
}

export interface PlayerStats {
    totalSessions: number;
    totalPlaytime: number;
    averageSession: number;
    recentSessions: PlayerSession[];
}

export interface ServerStats {
    last24Hours: {
        uniquePlayers: number;
        totalPlaytime: number;
        sessionCount: number;
    };
}

export interface PlayerAnalyticsEvent {
    action: 'recordSession' | 'getPlayerStats' | 'getServerStats';
    playerData?: {
        uuid: string;
        name: string;
        loginTime: number;
        logoutTime: number;
    };
    playerId?: string;
}

export interface AnalyticsMetric {
    MetricName: string;
    Value: number;
    Unit: 'Seconds' | 'Count';
    Dimensions: Array<{
        Name: string;
        Value: string;
    }>;
}