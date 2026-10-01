export interface PiSourceLock {
  repository: string;
  ref: string;
  commit: string;
}

export interface PiRequest {
  prompt: string;
  context?: Record<string, unknown>;
  signal?: AbortSignal;
}

export interface PiResponse {
  text: string;
  model?: string;
  metadata?: Record<string, unknown>;
}

/**
 * Pi 通过 bootstrap 脚本以外部源码运行；核心只依赖这个窄接口，避免把第三方实现编进应用。
 */
export interface PiAgentBackend {
  readonly source: PiSourceLock;
  run(request: PiRequest): Promise<PiResponse>;
}

export class UnconfiguredPiBackend implements PiAgentBackend {
  readonly source: PiSourceLock;

  constructor(source: PiSourceLock) {
    this.source = source;
  }

  async run(_request: PiRequest): Promise<PiResponse> {
    throw new Error("尚未配置 PiAgentBackend；请先执行 scripts/bootstrap-pi.sh 并在宿主层接入 Pi 运行器");
  }
}
