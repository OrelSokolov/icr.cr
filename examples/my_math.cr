# Shared library code: the host program uses it via a plain require,
# and the demo also requires this file from inside the icr session,
# so MyMath is available at the interactive prompt too.

module MyMath
  def self.square(x)
    x * x
  end
end
