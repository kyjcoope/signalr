package com.jci.mediaprocessor.media_processor;

import android.graphics.SurfaceTexture;
import android.opengl.GLES20;
import android.opengl.GLES30;
import android.opengl.GLUtils;
import android.util.Log;

import javax.microedition.khronos.egl.EGL10;
import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.egl.EGLContext;
import javax.microedition.khronos.egl.EGLDisplay;
import javax.microedition.khronos.egl.EGLSurface;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;

public abstract class BaseRenderer {
  static {
    System.loadLibrary("MediaProcessor");
  }

  public static native byte[] getBuffer(long ptr, int size);

  protected static final String LOG_TAG = "OpenGL.Worker";

  // ---- Lifecycle + thread-safety ----
  protected final Object glLock = new Object();
  private volatile boolean disposed = false;
  public boolean isDisposed() { return disposed; }

  // ---- Inputs / dims ----
  protected final SurfaceTexture texture;
  protected int width;
  protected int height;

  // ---- EGL / GL ----
  protected EGL10 egl;
  protected EGLDisplay eglDisplay;
  protected EGLContext eglContext;
  protected EGLSurface eglSurface;

  protected final int[] vbo = new int[1];
  protected final int[] vao = new int[1];
  protected final int[] ebo = new int[1];

  protected int mProgramHandle;

  protected final int[] mTextures = new int[3];

  /** Attribute locations */
  protected int mPositionHandle;

  /** Uniform handles (samplers etc.) */
  protected final int[] mYUVTextureHandle = new int[3];

  public BaseRenderer(SurfaceTexture texture, int width, int height) {
    this.texture = texture;
    this.width   = width;
    this.height  = height;
  }

  // ---- subclass hooks ----
  protected abstract String vertexShader();
  protected abstract String fragmentShader();
  protected abstract void connectTexturesToProgram();
  protected abstract void loadTexture(ByteBuffer[] buffers);
  public    abstract void drawTexture();
  public    abstract void setBuffer(byte[] inY, byte[] inU, byte[] inV);
  public    abstract void setBufferPtr(long ptr, int size);

  // ---- GL setup ----
  public void initGL() {
    synchronized (glLock) {
      if (disposed) return;

      egl = (EGL10) EGLContext.getEGL();
      eglDisplay = egl.eglGetDisplay(EGL10.EGL_DEFAULT_DISPLAY);
      if (eglDisplay == EGL10.EGL_NO_DISPLAY) {
        throw new RuntimeException("eglGetDisplay failed");
      }

      int[] version = new int[2];
      if (!egl.eglInitialize(eglDisplay, version)) {
        throw new RuntimeException("eglInitialize failed");
      }

      EGLConfig eglConfig = chooseEglConfig();
      eglContext = createContext(egl, eglDisplay, eglConfig);

      eglSurface = egl.eglCreateWindowSurface(eglDisplay, eglConfig, texture, null);
      if (eglSurface == null || eglSurface == EGL10.EGL_NO_SURFACE) {
        throw new RuntimeException("GL Error: " + GLUtils.getEGLErrorString(egl.eglGetError()));
      }

      if (!egl.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
        throw new RuntimeException("GL make current error: " + GLUtils.getEGLErrorString(egl.eglGetError()));
      }

      GLES20.glGenTextures(3, mTextures, 0);
    }
  }

  public void initShaders() {
    synchronized (glLock) {
      if (disposed) return;

      // --- vertex ---
      int vertexShaderHandle = GLES20.glCreateShader(GLES20.GL_VERTEX_SHADER);
      if (vertexShaderHandle == 0) throw new RuntimeException("glCreateShader vertex failed");
      GLES20.glShaderSource(vertexShaderHandle, vertexShader());
      GLES20.glCompileShader(vertexShaderHandle);
      int[] status = new int[1];
      GLES20.glGetShaderiv(vertexShaderHandle, GLES20.GL_COMPILE_STATUS, status, 0);
      if (status[0] == 0) {
        GLES20.glDeleteShader(vertexShaderHandle);
        throw new RuntimeException("Error creating vertex shader.");
      }

      // --- fragment ---
      int fragmentShaderHandle = GLES20.glCreateShader(GLES20.GL_FRAGMENT_SHADER);
      if (fragmentShaderHandle == 0) throw new RuntimeException("glCreateShader fragment failed");
      GLES20.glShaderSource(fragmentShaderHandle, fragmentShader());
      GLES20.glCompileShader(fragmentShaderHandle);
      GLES20.glGetShaderiv(fragmentShaderHandle, GLES20.GL_COMPILE_STATUS, status, 0);
      if (status[0] == 0) {
        String src = fragmentShader();
        GLES20.glDeleteShader(fragmentShaderHandle);
        throw new RuntimeException("Error creating fragment shader." + src);
      }

      // --- link program ---
      mProgramHandle = GLES20.glCreateProgram();
      if (mProgramHandle == 0) throw new RuntimeException("Error creating program.");
      GLES20.glAttachShader(mProgramHandle, vertexShaderHandle);
      GLES20.glAttachShader(mProgramHandle, fragmentShaderHandle);

      // Bind attributes before link
      GLES20.glBindAttribLocation(mProgramHandle, 0, "a_Position");
      GLES20.glBindAttribLocation(mProgramHandle, 2, "a_TexCoordinate");

      GLES20.glLinkProgram(mProgramHandle);
      int[] link = new int[1];
      GLES20.glGetProgramiv(mProgramHandle, GLES20.GL_LINK_STATUS, link, 0);
      if (link[0] == 0) {
        GLES20.glDeleteProgram(mProgramHandle);
        throw new RuntimeException("Error creating program.");
      }

      mPositionHandle = GLES20.glGetAttribLocation(mProgramHandle, "a_Position");
      connectTexturesToProgram();

      GLES20.glUseProgram(mProgramHandle);
    }
  }

  public void initBuffers() {
    synchronized (glLock) {
      if (disposed) return;

      float[] vertices = {
          // positions        // texcoords
           1.0f,  1.0f, 0.0f,   1.0f, 0.0f,
           1.0f, -1.0f, 0.0f,   1.0f, 1.0f,
          -1.0f, -1.0f, 0.0f,   0.0f, 1.0f,
          -1.0f,  1.0f, 0.0f,   0.0f, 0.0f
      };
      FloatBuffer bVertices = ByteBuffer
          .allocateDirect(vertices.length * Float.BYTES)
          .order(ByteOrder.nativeOrder())
          .asFloatBuffer();
      bVertices.put(vertices).position(0);

      int[] indices = { 0, 1, 3, 1, 2, 3 };
      IntBuffer bIndices = ByteBuffer
          .allocateDirect(indices.length * Integer.BYTES)
          .order(ByteOrder.nativeOrder())
          .asIntBuffer();
      bIndices.put(indices).position(0);

      GLES30.glGenVertexArrays(1, vao, 0);
      GLES30.glGenBuffers(1, vbo, 0);
      GLES30.glGenBuffers(1, ebo, 0);

      GLES30.glBindVertexArray(vao[0]);

      GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, vbo[0]);
      GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, vertices.length * Float.BYTES, bVertices, GLES20.GL_STATIC_DRAW);

      GLES20.glBindBuffer(GLES20.GL_ELEMENT_ARRAY_BUFFER, ebo[0]);
      GLES20.glBufferData(GLES20.GL_ELEMENT_ARRAY_BUFFER, indices.length * Integer.BYTES, bIndices, GLES20.GL_STATIC_DRAW);

      // a_Position @ location 0
      GLES20.glVertexAttribPointer(0, 3, GLES20.GL_FLOAT, false, 5 * Float.BYTES, 0);
      GLES20.glEnableVertexAttribArray(0);

      // a_TexCoordinate @ location 2
      GLES20.glVertexAttribPointer(2, 2, GLES20.GL_FLOAT, false, 5 * Float.BYTES, 3 * Float.BYTES);
      GLES20.glEnableVertexAttribArray(2);

      GLES30.glBindVertexArray(0);
    }
  }

  protected void deinitGL() {
    egl.eglMakeCurrent(eglDisplay, EGL10.EGL_NO_SURFACE, EGL10.EGL_NO_SURFACE, EGL10.EGL_NO_CONTEXT);
    egl.eglDestroySurface(eglDisplay, eglSurface);
    egl.eglDestroyContext(eglDisplay, eglContext);
    egl.eglTerminate(eglDisplay);
    Log.d(LOG_TAG, "OpenGL deinit OK.");
  }

  public void onDispose() {
    synchronized (glLock) {
      if (disposed) return;
      disposed = true; // mark first so in-flight calls bail out

      try { egl.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext); } catch (Throwable ignored) {}

      try { GLES20.glDeleteTextures(3, mTextures, 0); } catch (Throwable ignored) {}
      try { GLES20.glDeleteBuffers(1, vbo, 0); }      catch (Throwable ignored) {}
      try { GLES20.glDeleteBuffers(1, ebo, 0); }      catch (Throwable ignored) {}
      try { GLES30.glDeleteVertexArrays(1, vao, 0); } catch (Throwable ignored) {}

      try { deinitGL(); } catch (Throwable ignored) {}
    }
  }

  // ---- EGL helpers ----
  protected EGLContext createContext(EGL10 egl, EGLDisplay dpy, EGLConfig cfg) {
    final int EGL_CONTEXT_CLIENT_VERSION = 0x3098;
    int[] attribList = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL10.EGL_NONE };
    return egl.eglCreateContext(dpy, cfg, EGL10.EGL_NO_CONTEXT, attribList);
  }

  protected EGLConfig chooseEglConfig() {
    int[] count = new int[1];
    EGLConfig[] cfgs = new EGLConfig[1];
    int[] spec = getConfig();
    if (!egl.eglChooseConfig(eglDisplay, spec, cfgs, 1, count)) {
      throw new IllegalArgumentException("Failed to choose config: " + GLUtils.getEGLErrorString(egl.eglGetError()));
    } else if (count[0] > 0) {
      return cfgs[0];
    }
    return null;
  }

  private int[] getConfig() {
    return new int[] {
        EGL10.EGL_RENDERABLE_TYPE, 4,
        EGL10.EGL_RED_SIZE,   8,
        EGL10.EGL_GREEN_SIZE, 8,
        EGL10.EGL_BLUE_SIZE,  8,
        EGL10.EGL_ALPHA_SIZE, 8,
        EGL10.EGL_DEPTH_SIZE,   0,
        EGL10.EGL_STENCIL_SIZE, 0,
        EGL10.EGL_NONE
    };
  }

  @Override
  protected void finalize() throws Throwable {
    super.finalize();
  }
}
