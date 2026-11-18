#pragma once
#include <string>
#include <optional>
#include <memory>
#include <utility>
#include <cstdio>
namespace android { namespace base {
struct ResultError { int code_ = -1; std::string msg_; int code() const { return code_; } const std::string& message() const { return msg_; } };
template <typename T> class Result { public:
  Result(T v) : v_(std::move(v)) {}
  template <typename U> Result(U&& v) requires std::is_convertible_v<U, T> : v_(T(std::forward<U>(v))) {}
  Result(ResultError e) : e_(std::move(e)) {}
  bool ok() const { return v_.has_value(); } T& operator*() { return *v_; } T& value() { return *v_; }
  const ResultError& error() const { return e_; }
private: std::optional<T> v_; ResultError e_; };
template <typename... A> ResultError Errorf(const char* fmt, A&&...) { return ResultError{-1, fmt}; }
}}
namespace android { using base::Errorf; }
