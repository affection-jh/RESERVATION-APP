# lib과 assets만 Pull 받는 방법

## 설정 방법

### 올릴 때 (Push)
- 일반적으로 전체를 올리면 됩니다
- `.gitignore`에 의해 빌드 파일 등은 자동으로 제외됩니다

### 받을 때 (Pull) - Sparse Checkout 사용

**기존 저장소에서 설정:**

```bash
# 1. Sparse checkout 초기화
git sparse-checkout init --cone

# 2. lib과 assets만 받도록 설정
git sparse-checkout set lib assets .gitignore pubspec.yaml pubspec.lock README.md

# 3. 설정 적용
git read-tree -mu HEAD
```

**새로 클론하는 경우:**

```bash
# 1. 체크아웃 없이 클론
git clone --no-checkout <repository-url> reservation
cd reservation

# 2. Sparse checkout 초기화
git sparse-checkout init --cone

# 3. lib과 assets만 받도록 설정
git sparse-checkout set lib assets .gitignore pubspec.yaml pubspec.lock README.md

# 4. 체크아웃
git checkout
```

### 일상적인 사용

**Push (올리기):**
```bash
git add .
git commit -m "코드 업데이트"
git push
```

**Pull (받기):**
```bash
git pull
# sparse checkout이 설정되어 있으면 lib과 assets만 받아집니다
```

### Sparse Checkout 해제 (전체 파일 받기)

```bash
git sparse-checkout disable
git read-tree -mu HEAD
```

## 주의사항

- Sparse checkout을 설정하면 지정한 폴더만 받아집니다
- 다른 폴더의 파일은 로컬에 없어도 git은 추적합니다
- 필요시 `git sparse-checkout disable`로 해제할 수 있습니다
