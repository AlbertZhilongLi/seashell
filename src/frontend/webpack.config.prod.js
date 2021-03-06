const path = require('path');
const webpack = require('webpack');
const CopyWebpackPlugin = require('copy-webpack-plugin');
const HtmlWebpackPlugin = require('html-webpack-plugin');
const CleanWebpackPlugin = require('clean-webpack-plugin');
const OfflinePlugin = require('offline-plugin');
const ArchivePlugin = require('webpack-archive-plugin');
const EmptyPlugin = function() {
  return {apply: function() {}};
}

module.exports = function(env) {
  let debug = !!(env ? env.debug : true);

  return {
  devtool: 'source-map',
  entry: './src/index.tsx',
  output: {
    path: path.join(__dirname, 'dist'),
    filename: 'bundle.[chunkhash].js',
    publicPath: './'
  },
  plugins: [
    new CleanWebpackPlugin(['dist'], { verbose: false }),
    new CopyWebpackPlugin([
      { from: 'images/', to: 'images/' },
      {
        from: 'favicon.ico'
      },
      { from: 'manifest.json' },
      {
        from: './node_modules/monaco-editor/min/vs',
        to: 'vs',
      },
      { context: './node_modules/seashell-clang-js/bin/',
        from: '*.mem', to: './' },
      { context: './node_modules/seashell-clang-js/bin/',
        from: '*.data', to: './' },
    ]),
    new webpack.DefinePlugin({
      'process.env.NODE_ENV': JSON.stringify('production'),
      IS_BROWSER: true,
      PRODUCTION: true,
      DEBUG: debug,
      VERSION: env && env.version && JSON.stringify(env.version) || "'manual'",
      DOMAIN: env && env.version && JSON.stringify(env.domain) || "'uwaterloo.ca'"
    }),
    new HtmlWebpackPlugin ({
      inject: true,
      template: './src/index.html'
    }),
    new ArchivePlugin(),
    new OfflinePlugin({
      ServiceWorker:{
        navigateFallbackURL: '/'
      }
    }),
    debug ? EmptyPlugin() :
      new webpack.optimize.UglifyJsPlugin({
        compress: {
          warnings: true,
        },
        sourceMap: true,
        minimize: true
      }),
  ],
  resolve: {
      // Add '.ts' and '.tsx' as resolvable extensions.
      extensions: [".webpack.js", ".web.js", ".ts", ".tsx", ".js", ".scss"]
  },
  module: {
    rules: [
      { enforce: 'pre', test: /\.js$/, loader: "source-map-loader" },
      { enforce: 'pre', test: /\.tsx?$/, loader: "tslint-loader" },
      { test: /\.tsx?$/, loader: "awesome-typescript-loader" },
      {
        test: /\.scss$/,
        use: [
          'style-loader?sourceMap',
          'css-loader?modules&importLoaders=1&localIdentName=[path]___[name]__[local]___[hash:base64:5]',
          'sass-loader?sourceMap'
        ]
      }, {
        test: /\.css$/,
        use: ["style-loader", "css-loader"]
      }, {
        test: /\.(woff|woff2|ttf|eot)$/,
        use: ['file-loader']
      },
      {
        test: /\.(jpe?g|png|gif|svg)$/i,
        use: [
          'file-loader?hash=sha512&digest=hex&name=[hash].[ext]',
          'image-webpack-loader?{bypassOnDebug: true, optipng: {optimizationLevel: 7}, gifsicle: {interlaced: false}}'
        ]
      }
    ],
  },
};};
