# 제작 기록 (DEVLOG)

앱을 만든 과정과, 중간에 막혔던 오류의 원인·해결을 기록합니다.
구현 → 빌드 오류 → 수정을 반복했습니다.

## 요구사항

- 강의 영상에서 음성만 분리하는 macOS 네이티브 앱
- 영상을 드래그 앤 드롭하면 추출 시작
- 여러 영상 동시 투입, 진행 상황 표시 등 사용성 고려

## 타임라인

### 1. 초기 구현: SwiftUI + AVFoundation + 수작업 Xcode 프로젝트
- `ExtractionManager`(작업 큐)와 SwiftUI 뷰(드롭 영역, 작업 목록, 진행 바)를 구현했습니다.
- `.xcodeproj/project.pbxproj`를 직접 작성해 함께 전달했습니다.

### 2. 오류 ①: Xcode가 프로젝트를 열지 못함
```
The project 'AudioExtractor' is damaged and cannot be opened.
Exception: -[XCConfigurationList name]: unrecognized selector
```
- **원인**: 손으로 쓴 `project.pbxproj`에서 서로 다른 객체(프로젝트용 `XCConfigurationList`와 Debug 빌드 설정)가 같은 ID를 공유했습니다.
- **해결**: pbxproj를 직접 만들지 않고 **Swift Package Manager** 구조(`Package.swift` + `Sources/`)로 전환했습니다.
- **배운 점**: 파서가 엄격한 생성 파일은 손으로 쓰기보다 도구가 만들게 하는 편이 안전합니다.

### 3. 오류 ②: macOS 14 전용 API 사용
```
error: 'symbolEffect(_:options:isActive:)' is only available in macOS 14.0 or newer
```
- **원인**: 배포 타깃은 macOS 13인데 `symbolEffect(.pulse)`는 macOS 14부터 가능합니다.
- **해결**: 해당 효과를 제거했습니다. (`#available` 분기로 살릴 수도 있습니다.)

### 4. 오류 ③: `AVAssetExportSession`의 동시성(Sendable) 경고/오류
```
warning: passing argument of non-sendable type 'AVAssetExportSession' outside of main actor-isolated context
error: expression is 'async' but is not marked with 'await'
error: 'async' call in a function that does not support concurrency
```
- `AVAssetExportSession`은 `Sendable`이 아니라서 Actor 경계를 넘길 때 경고가 납니다.
- 시도한 방법과 결과:
  1. `Task.detached` + `Timer`로 `session.export()` 호출 → 최신 SDK에서 `export()`가 `async`라서 `await` 오류
  2. `Thread { session.export() }` → 같은 이유로 "async 호출을 지원하지 않는 함수" 오류, `Thread.sleep` 경고 추가
  3. **`exportAsynchronously` + `withCheckedContinuation`** 으로 콜백을 `async`로 감싸고, 진행률은 메인 스레드 `Timer`로 폴링 → 빌드 및 동작 확인 (최종)
- 최종 구조:
```swift
let (status, error) = await withCheckedContinuation { continuation in
    session.exportAsynchronously {
        continuation.resume(returning: (session.status, session.error))
    }
}
```
- **참고**: `session`을 `@Sendable` 클로저에서 캡처하는 부분은 Swift 6 언어 모드에서는 재검토가 필요할 수 있습니다.
  (Swift 5 모드에서 빌드/동작하는 것을 확인했습니다.)

### 5. 배포 질문: Launchpad / App Store
- 현재는 `swift build`로 만든 실행 파일이라 Launchpad에 바로 등록되지 않습니다.
- Launchpad 실행과 App Store 제출을 위해서는 `.app` 번들, `Info.plist`, 앱 아이콘, App Sandbox, 코드 서명/공증이 필요합니다. 로드맵에 반영했습니다.

## 회고

- 코드는 **실제 환경(macOS/Xcode)에서 빌드해 보기 전까지는 검증되지 않은 상태**였고, 오류 메시지를 근거로 하나씩 수정하는 방식이 효과적이었습니다.
- 생성 파일(pbxproj)과 최신 SDK의 동시성 규칙처럼 **환경에 민감한 부분에서 오류가 집중**됐습니다.
- 형식 지원(mkv/avi/webm)은 코드의 확장자 목록과 프레임워크의 실제 지원 범위가 다를 수 있어, 다음 개선 항목으로 남겼습니다.
