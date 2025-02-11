export interface PlayerCohort {
    week: number;
    players: string[];
    retention: {
        [key: string]: number;  // e.g., week1: 85.5
    };
}

export interface RetentionMetrics {
    MetricName: string;
    Value: number;
    Unit: 'Percent';
    Dimensions: Array<{
        Name: string;
        Value: string;
    }>;
}

export interface RetentionEvent {
    action?: string;
    startDate?: string;
    endDate?: string;
}

export interface CohortAnalysis {
    cohorts: PlayerCohort[];
    summary: {
        averageWeek1Retention: number;
        retentionTrend: 'increasing' | 'decreasing' | 'stable';
        totalPlayersAnalyzed: number;
    };
}

export interface RetentionAlert {
    type: 'low_retention' | 'declining_trend' | 'improving_trend';
    value: number;
    threshold: number;
    message: string;
    recommendations: string[];
}